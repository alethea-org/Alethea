defmodule AletheaJobs.ClinicalRecordOutboxWorkerTest do
  @moduledoc """
  Tests for `AletheaJobs.ClinicalRecordOutboxWorker`
  (sdd/clinical-rag-projection, GitHub #196, WU3/PR3, Phase 4 tasks
  4.1-4.2).

  REWRITTEN (not extended) per design section 4: the prior version
  locked three contracts this change intentionally breaks —
  unconditional `:ok`, `max_attempts == 1`, and `FunctionClauseError`
  on malformed args. This worker now dispatches every eligible event
  to `Alethea.ClinicalRecord.Rag.Indexer.index_event/1` and classifies
  its result: `:ok` passes through; `{:cancel, _}` (dimension
  mismatch, malformed args, missing source row) is a permanent
  failure; any other `{:error, _}` is transient and retries under the
  new `max_attempts: 5`.
  """
  use Alethea.DataCase, async: true
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord.Rag.Chunk
  alias AletheaJobs.ClinicalRecordOutboxWorker

  setup :verify_on_exit!

  describe "job options" do
    test "queue is :clinical_record_outbox with max_attempts 5 (was 1)" do
      changeset =
        ClinicalRecordOutboxWorker.new(%{
          "event" => "target_behavior_created",
          "resource_type" => "target_behavior",
          "resource_id" => Ecto.UUID.generate(),
          "patient_id" => Ecto.UUID.generate(),
          "professional_id" => Ecto.UUID.generate()
        })

      assert Ecto.Changeset.get_change(changeset, :queue) == "clinical_record_outbox"
      assert Ecto.Changeset.get_change(changeset, :max_attempts) == 5
    end
  end

  describe "perform/1 — malformed args cancel instead of raising" do
    test "missing identifier key cancels with the malformed_args reason (not FunctionClauseError)" do
      args = %{
        "event" => "target_behavior_created",
        "resource_type" => "target_behavior",
        "resource_id" => Ecto.UUID.generate()
      }

      assert {:cancel, {:malformed_args, keys}} =
               perform_job(ClinicalRecordOutboxWorker, args)

      assert Enum.sort(keys) == Enum.sort(Map.keys(args))
    end

    test "a different missing key (triangulation) also cancels instead of raising" do
      args = %{
        "event" => "target_behavior_created",
        "patient_id" => Ecto.UUID.generate(),
        "professional_id" => Ecto.UUID.generate()
      }

      assert {:cancel, {:malformed_args, keys}} =
               perform_job(ClinicalRecordOutboxWorker, args)

      assert Enum.sort(keys) == Enum.sort(Map.keys(args))
    end
  end

  describe "perform/1 — ignore/unknown eligibility acks :ok without indexing" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "target_behavior_created (structural metadata) is :ok, no chunk created", %{
      professional: professional,
      patient: patient
    } do
      args = %{
        "event" => "target_behavior_created",
        "resource_type" => "target_behavior",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = perform_job(ClinicalRecordOutboxWorker, args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end

    test "an unrecognized event (tombstone seam, #197) is :ok without raising or indexing", %{
      professional: professional,
      patient: patient
    } do
      args = %{
        "event" => "clinical_record_deleted",
        "resource_type" => "clinical_note",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = perform_job(ClinicalRecordOutboxWorker, args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end
  end

  describe "perform/1 — dispatches eligible events to Indexer.index_event/1" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "clinical_note_created is genuinely indexed (real chunk row, not a no-op)", %{
      professional: professional,
      patient: patient
    } do
      {:ok, note} =
        Alethea.ClinicalRecord.create_clinical_note(
          professional,
          patient.id,
          "El paciente refiere mejoría notable en la última sesión."
        )

      args = %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => note.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = perform_job(ClinicalRecordOutboxWorker, args)

      chunks =
        Chunk |> Alethea.Repo.all() |> Enum.filter(&(&1.source_resource_id == note.id))

      assert length(chunks) == 1
    end
  end

  describe "perform/1 — missing source row cancels (permanent, not a retry)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "an indexable event pointing at a nonexistent resource cancels with :not_found", %{
      professional: professional,
      patient: patient
    } do
      args = %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert {:cancel, :not_found} = perform_job(ClinicalRecordOutboxWorker, args)
    end
  end

  describe "perform/1 — transient failures surface as {:error, _} for Oban to retry" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)

      original = Application.get_env(:alethea, :ai_embeddings)
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, original, persistent: true)
      end)

      %{professional: professional, patient: patient}
    end

    test "an embedding adapter timeout is {:error, _}, not {:cancel, _}", %{
      professional: professional,
      patient: patient
    } do
      {:ok, note} =
        Alethea.ClinicalRecord.create_clinical_note(
          professional,
          patient.id,
          "Texto breve para simular una falla transitoria del proveedor de embeddings."
        )

      Alethea.AI.EmbeddingsMock
      |> expect(:embed, fn _texts, [] -> {:error, :timeout} end)

      args = %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => note.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert {:error, :timeout} = perform_job(ClinicalRecordOutboxWorker, args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "rag-worker-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Worker"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end
end
