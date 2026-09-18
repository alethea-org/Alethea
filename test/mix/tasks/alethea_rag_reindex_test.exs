defmodule Mix.Tasks.Alethea.Rag.ReindexTest do
  @moduledoc """
  Tests for `mix alethea.rag.reindex` (sdd/clinical-rag-projection,
  GitHub #196, WU5/PR5, Phase 6 tasks 6.1-6.2).

  Per design section 6: this is an on-demand recovery tool that
  re-enqueues one outbox job per currently INDEX-eligible resource
  through the SAME `Outbox` -> `ClinicalRecordOutboxWorker` ->
  `Indexer` path incremental ingest already uses. It never embeds
  inline and never runs on a schedule (spec's "On-Demand Rebuild"
  requirement — no cron/periodic trigger exists anywhere for this).

  Covers:
  - Argument validation (missing/unknown patient id).
  - Dry run (no `--confirm`): reports counts, writes nothing.
  - `--confirm`: enqueues exactly one job per eligible resource,
    excluding `target_behavior` (structural metadata, never indexed)
    and non-`accepted` `AIProposal` rows (spec: pending/edited/
    discarded are never indexed).
  - End-to-end idempotency: draining the queue twice (via two
    `--confirm` runs) converges to exactly one chunk per resource, no
    duplicates — proven against the real `Indexer`/`Chunk` table, not
    a structural proxy.
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import ExUnit.CaptureIO

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.AIProposal
  alias Alethea.ClinicalRecord.Rag.Chunk
  alias AletheaJobs.ClinicalRecordOutboxWorker

  @worker "AletheaJobs.ClinicalRecordOutboxWorker"

  test "requires a patient id" do
    assert_raise Mix.Error,
                 "usage: mix alethea.rag.reindex --patient-id <uuid> [--confirm]",
                 fn ->
                   capture_io(:stderr, fn -> run_task([]) end)
                 end
  end

  test "an unknown patient id fails closed" do
    assert_raise Mix.Error, "ALETHEA_RAG_REINDEX_FAILED reason=patient_not_found", fn ->
      capture_io(:stderr, fn -> run_task(["--patient-id", Ecto.UUID.generate()]) end)
    end
  end

  test "dry run reports per-resource-type counts and enqueues nothing" do
    %{patient: patient} = seed_eligible_and_ineligible_resources!()
    drain_outbox!()

    output = capture_io(fn -> run_task(["--patient-id", patient.id]) end)

    assert output =~ "ALETHEA_RAG_REINDEX_DRY_RUN"
    assert output =~ "clinical_note=1"
    assert output =~ "consultation_evidence=1"
    assert output =~ "clinician_observation=1"
    assert output =~ "ai_proposal=1"
    assert output =~ "functional_analysis_draft=1"
    assert output =~ "total=5"

    refute_enqueued(worker: @worker, args: %{"patient_id" => patient.id})
  end

  test "--confirm enqueues exactly one job per eligible resource, excluding target_behavior and non-accepted proposals" do
    %{patient: patient, professional: professional} = seed_eligible_and_ineligible_resources!()
    drain_outbox!()

    output = capture_io(fn -> run_task(["--patient-id", patient.id, "--confirm"]) end)

    assert output =~ "ALETHEA_RAG_REINDEX_COMPLETE"
    assert output =~ "enqueued=5"

    enqueued =
      all_enqueued(worker: ClinicalRecordOutboxWorker)
      |> Enum.filter(&(&1.args["patient_id"] == patient.id))

    assert length(enqueued) == 5

    events = Enum.map(enqueued, & &1.args["event"]) |> Enum.sort()

    assert events ==
             Enum.sort([
               "clinical_note_created",
               "consultation_evidence_created",
               "clinician_observation_created",
               "ai_proposal_accepted",
               "functional_analysis_draft_saved"
             ])

    refute Enum.any?(enqueued, &(&1.args["professional_id"] not in [professional.id]))
  end

  test "--confirm reports enqueue failures and never emits COMPLETE for a partial run" do
    %{patient: patient} = seed_eligible_and_ineligible_resources!()
    drain_outbox!()

    original = Application.get_env(:alethea, :rag_reindex_enqueue)

    Application.put_env(:alethea, :rag_reindex_enqueue, fn _changeset ->
      {:error, :unavailable}
    end)

    on_exit(fn ->
      Application.put_env(:alethea, :rag_reindex_enqueue, original)
    end)

    output =
      capture_io(fn ->
        assert_raise Mix.Error,
                     "ALETHEA_RAG_REINDEX_FAILED reason=enqueue_failed enqueued=0 failed=5",
                     fn ->
                       run_task(["--patient-id", patient.id, "--confirm"])
                     end
      end)

    assert output =~ "ALETHEA_RAG_REINDEX_FAILED reason=enqueue_failed enqueued=0 failed=5"
    refute output =~ "ALETHEA_RAG_REINDEX_COMPLETE"
    refute_enqueued(worker: @worker, args: %{"patient_id" => patient.id})
  end

  test "converges to one chunk per resource across two --confirm runs (idempotent, no duplicates)" do
    %{patient: patient} = seed_eligible_and_ineligible_resources!()
    drain_outbox!()

    capture_io(fn -> run_task(["--patient-id", patient.id, "--confirm"]) end)
    drain_outbox!()

    first_chunk_count = chunk_count(patient.id)
    assert first_chunk_count == 5

    capture_io(fn -> run_task(["--patient-id", patient.id, "--confirm"]) end)
    drain_outbox!()

    assert chunk_count(patient.id) == first_chunk_count
  end

  describe "patient_message inclusion (sdd/telegram-rag-ingestion-262 #262, Slice 1)" do
    test "dry run counts only inbound messages, excluding outbound replies" do
      %{patient: patient} = seed_inbound_and_outbound_messages!()
      drain_outbox!()

      output = capture_io(fn -> run_task(["--patient-id", patient.id]) end)

      assert output =~ "ALETHEA_RAG_REINDEX_DRY_RUN"
      assert output =~ "patient_message=2"

      refute_enqueued(worker: @worker, args: %{"patient_id" => patient.id})
    end

    test "--confirm enqueues exactly one job per inbound message, routed through Clinical.Outbox" do
      %{patient: patient, professional: professional} = seed_inbound_and_outbound_messages!()
      drain_outbox!()

      output = capture_io(fn -> run_task(["--patient-id", patient.id, "--confirm"]) end)

      assert output =~ "ALETHEA_RAG_REINDEX_COMPLETE"
      assert output =~ "patient_message=2"

      enqueued =
        all_enqueued(worker: ClinicalRecordOutboxWorker)
        |> Enum.filter(&(&1.args["patient_id"] == patient.id))
        |> Enum.filter(&(&1.args["event"] == "patient_message_received"))

      assert length(enqueued) == 2
      assert Enum.all?(enqueued, &(&1.args["resource_type"] == "patient_message"))
      assert Enum.all?(enqueued, &(&1.args["professional_id"] == professional.id))
    end

    test "converges to one chunk per inbound message across two --confirm runs (idempotent, no duplicates)" do
      %{patient: patient} = seed_inbound_and_outbound_messages!()
      drain_outbox!()

      capture_io(fn -> run_task(["--patient-id", patient.id, "--confirm"]) end)
      drain_outbox!()

      first_count = patient_message_chunk_count(patient.id)
      assert first_count == 2

      capture_io(fn -> run_task(["--patient-id", patient.id, "--confirm"]) end)
      drain_outbox!()

      assert patient_message_chunk_count(patient.id) == first_count
    end
  end

  defp patient_message_chunk_count(patient_id) do
    import Ecto.Query

    Chunk
    |> where([c], c.patient_id == ^patient_id and c.source_resource_type == "patient_message")
    |> Repo.aggregate(:count)
  end

  defp seed_inbound_and_outbound_messages! do
    professional = create_professional!()
    patient = create_patient!(professional)

    {:ok, _inbound_1} =
      Clinical.save_message(patient, "Me siento mejor hoy.", nil, "inbound", "spontaneous")

    {:ok, _inbound_2} =
      Clinical.save_message(patient, "Dormi bien anoche.", nil, "inbound", "spontaneous")

    {:ok, _outbound} =
      Clinical.save_message(patient, "Que bueno escuchar eso.", nil, "outbound", "elicited")

    %{professional: professional, patient: patient}
  end

  defp run_task(args) do
    Mix.Task.reenable("alethea.rag.reindex")
    Mix.Tasks.Alethea.Rag.Reindex.run(args)
  end

  defp drain_outbox! do
    Oban.drain_queue(queue: :clinical_record_outbox)
  end

  defp chunk_count(patient_id) do
    import Ecto.Query
    Chunk |> where([c], c.patient_id == ^patient_id) |> Repo.aggregate(:count)
  end

  defp seed_eligible_and_ineligible_resources! do
    professional = create_professional!()
    patient = create_patient!(professional)

    {:ok, target_behavior} =
      ClinicalRecord.create_target_behavior(professional, patient.id, "Evita el contacto social")

    {:ok, _note} =
      ClinicalRecord.create_clinical_note(
        professional,
        patient.id,
        "El paciente refiere mejoría en la última sesión."
      )

    {:ok, _evidence} =
      ClinicalRecord.add_consultation_evidence(professional, patient.id, target_behavior.id, %{
        source_kind: "clinical_note",
        source_id: Ecto.UUID.generate(),
        excerpt: "Extracto citado de la nota clínica.",
        occurred_at: DateTime.utc_now()
      })

    {:ok, _observation} =
      ClinicalRecord.add_clinician_observation(
        professional,
        patient.id,
        target_behavior.id,
        "Observación directa del clínico durante la sesión."
      )

    {:ok, _draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target_behavior.id,
        "Borrador de análisis funcional en curso."
      )

    accepted_proposal =
      insert_ai_proposal!(professional, patient, target_behavior, "accepted")

    _pending_proposal =
      insert_ai_proposal!(professional, patient, target_behavior, "pending")

    %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior,
      accepted_proposal: accepted_proposal
    }
  end

  defp insert_ai_proposal!(professional, patient, target_behavior, status) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt("Propuesta generada por IA.", dek)

    Repo.insert!(%AIProposal{
      encrypted_original_text: ciphertext,
      encrypted_text: ciphertext,
      status: status,
      model_version: "test-model",
      occurred_at: DateTime.utc_now(),
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id
    })
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "rag-reindex-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Reindex"
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
