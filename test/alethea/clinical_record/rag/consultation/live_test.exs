defmodule Alethea.ClinicalRecord.Rag.Consultation.LiveTest do
  @moduledoc """
  Core outcome mapping for `Rag.Consultation.Live` (#232a, Phase 4 tasks
  4.1-4.8): authz precondition, freshness pre-gate + post-retrieval
  re-check (AD9), evidence-threshold filter (AD10), sanitize-then-
  synthesize (AD7), and the server-only source provenance guarantee
  (no LLM-fabricated citation ever reaches `Answer.sources`). Driven
  against real `Retrieval` + seeded chunks, with
  `ClinicalConsultationChainMock` standing in for the LLM (Mox against
  `ChainBehaviour`) — mirrors `retrieval_test.exs`'s fixture patterns.
  """
  use Alethea.DataCase, async: true
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias Alethea.AI.ClinicalConsultationChainMock
  alias Alethea.ClinicalRecord.Rag.Consultation
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Live, Source}
  alias Alethea.ClinicalRecord.Rag.{Chunk, Indexer, Retrieval}
  alias Alethea.ClinicalRecord.Tombstone
  alias Alethea.Encryption.PatientVault
  alias AletheaJobs.ClinicalRecordOutboxWorker

  setup :verify_on_exit!

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  # --- 4.1 authz precondition ---------------------------------------------

  describe "answer/4 — failed authorization never reaches retrieval" do
    test "a non-treating professional never reaches retrieval or the chain", %{patient: patient} do
      stranger = create_professional!()
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)
      expect_embeddings_never_called()

      assert {:error, :unauthorized} = Live.answer(stranger, patient.id, "q", [])
    end
  end

  # --- 4.2 stale pre-gate ---------------------------------------------------

  describe "answer/4 — pending indexing blocks the answer" do
    test "a pending outbox job blocks with the pending count before any decryption", %{
      professional: professional,
      patient: patient
    } do
      insert_pending_job!(professional, patient)
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)
      expect_embeddings_never_called()

      assert {:ok, %Answer{outcome: :stale, pending: 1, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "q", [])
    end
  end

  # --- 4.3 fresh-per-turn ----------------------------------------------------

  describe "answer/4 — retrieval re-runs on every turn" do
    test "two turns in one conversation issue two full retrievals, never cached or narrowed", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(
        professional,
        patient,
        "El paciente mejora su animo esta semana",
        near_vector()
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 2, fn _params ->
        {:ok, %{synthesis: "sintesis"}}
      end)

      assert {:ok, %Answer{outcome: :synthesis}} =
               Live.answer(professional, patient.id, "animo", [])

      assert {:ok, %Answer{outcome: :synthesis}} =
               Live.answer(professional, patient.id, "animo otra vez",
                 history: [%{role: :professional, content: "animo"}]
               )
    end
  end

  # --- 4.4 resolve_query/2 pure table test -----------------------------------

  describe "resolve_query/2 — pure, professional-only, never evidence" do
    test "uses only role: :professional turns and never derives a Source from history text" do
      history = [
        %{role: :assistant, content: "Segun los fragmentos citados el paciente mejora"},
        %{role: :professional, content: "¿cómo va el ánimo?"}
      ]

      assert Live.resolve_query("¿y sobre eso?", history) == "¿y sobre eso?"
      assert Live.resolve_query("¿y sobre eso?", []) == "¿y sobre eso?"
    end
  end

  # --- 4.5 no_evidence ---------------------------------------------------------

  describe "answer/4 — no_evidence" do
    test "empty results yield no_evidence", %{professional: professional, patient: patient} do
      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "consulta", [])
    end

    test "all results below the evidence threshold yield no_evidence (seeded chunks)", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(
        professional,
        patient,
        "Se ajusta el horario de la proxima cita",
        far_vector()
      )

      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "evitacion social ansiedad", [])
    end
  end

  # --- 4.6/4.7 synthesis + server-derived sources ------------------------------

  describe "answer/4 — synthesis on sufficient evidence" do
    test "at least one sufficient result proceeds to synthesis with envelope-derived sources", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(
        professional,
        patient,
        "El paciente reporta mejoria del animo esta semana",
        near_vector()
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn %{question: q, excerpts: excerpts} ->
        assert q == "¿cómo va el ánimo?"
        assert excerpts == ["El paciente reporta mejoria del animo esta semana"]
        {:ok, %{synthesis: "El paciente mejora su animo."}}
      end)

      assert {:ok,
              %Answer{
                outcome: :synthesis,
                synthesis: "El paciente mejora su animo.",
                sources: [%Source{} = source]
              }} = Live.answer(professional, patient.id, "¿cómo va el ánimo?", [])

      assert source.excerpt == "El paciente reporta mejoria del animo esta semana"
    end

    test "the LLM cannot inject or fabricate a source", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(
        professional,
        patient,
        "El paciente reporta mejoria del animo esta semana",
        near_vector()
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok,
         %{
           synthesis:
             "Segun el informe del Dr. Fantasma del 01/01/2000 (chunk_id fabricated-uuid), el paciente mejora."
         }}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: sources}} =
               Live.answer(professional, patient.id, "animo", [])

      {:ok, %{results: results}} = Retrieval.search(professional, patient.id, "animo")
      kept = Enum.filter(results, &(&1.score >= Consultation.evidence_threshold()))

      assert sources == Source.from_results(kept)
    end
  end

  # --- 4.8 provider_failure is a safe state -------------------------------------

  describe "answer/4 — provider_failure is a safe state" do
    setup %{professional: professional, patient: patient} do
      insert_chunk!(
        professional,
        patient,
        "El paciente reporta mejoria del animo esta semana",
        near_vector()
      )

      stub_query_embedding(near_vector())
      :ok
    end

    test "chain returning {:error, _} yields provider_failure", %{
      professional: professional,
      patient: patient
    } do
      expect(ClinicalConsultationChainMock, :run, 1, fn _params -> {:error, :unparseable} end)

      assert {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "animo", [])
    end

    test "chain returning a blank synthesis yields provider_failure, never blank prose", %{
      professional: professional,
      patient: patient
    } do
      expect(ClinicalConsultationChainMock, :run, 1, fn _params -> {:ok, %{synthesis: "   "}} end)

      assert {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "animo", [])
    end

    test "chain raising an exception yields provider_failure", %{
      professional: professional,
      patient: patient
    } do
      expect(ClinicalConsultationChainMock, :run, 1, fn _params -> raise "boom" end)

      assert {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "animo", [])
    end
  end

  # --- 5.1 cross-patient isolation ---------------------------------------------

  describe "answer/4 — cross-patient isolation (adversarial query)" do
    test "an adversarial query matching patient B's secret chunk never surfaces it while consulting patient A",
         %{professional: professional, patient: patient_a} do
      patient_b = create_patient!(professional)

      secret_b_text = "El paciente B reporta ideacion suicida activa y un plan concreto"
      leaked_resource_id = insert_chunk!(professional, patient_b, secret_b_text, near_vector())

      matching_a_id =
        insert_chunk!(
          professional,
          patient_a,
          "Nota rutinaria sobre el paciente A",
          near_vector()
        )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok, %{synthesis: "sintesis A"}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: sources}} =
               Live.answer(professional, patient_a.id, secret_b_text, [])

      returned_resource_ids = Enum.map(sources, & &1.reference.resource_id)
      refute leaked_resource_id in returned_resource_ids
      assert returned_resource_ids == [matching_a_id]
    end
  end

  # --- 5.2 cross-tenant isolation ------------------------------------------------

  describe "answer/4 — cross-tenant isolation (adversarial query)" do
    test "professional 1 consulting their own patient never retrieves professional 2's chunk" do
      professional_1 = create_professional!()
      patient_1 = create_patient!(professional_1)
      professional_2 = create_professional!()
      patient_2 = create_patient!(professional_2)

      secret_text = "El paciente del Dr. 2 reporta un intento previo"
      leaked_resource_id = insert_chunk!(professional_2, patient_2, secret_text, near_vector())

      own_id =
        insert_chunk!(professional_1, patient_1, "Nota rutinaria del Dr. 1", near_vector())

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok, %{synthesis: "sintesis 1"}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: sources}} =
               Live.answer(professional_1, patient_1.id, secret_text, [])

      returned_resource_ids = Enum.map(sources, & &1.reference.resource_id)
      refute leaked_resource_id in returned_resource_ids
      assert returned_resource_ids == [own_id]
    end
  end

  # --- 5.3 read-only guarantee ----------------------------------------------------

  describe "answer/4 — clinical state is never mutated" do
    test "a synthesis turn leaves chunks and oban jobs byte-identical", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, "El paciente reporta mejoria del animo", near_vector())
      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok, %{synthesis: "sintesis"}}
      end)

      before_snapshot = state_snapshot()

      assert {:ok, %Answer{outcome: :synthesis}} =
               Live.answer(professional, patient.id, "animo", [])

      assert state_snapshot() == before_snapshot
    end

    test "a blocking (stale) turn leaves chunks and oban jobs byte-identical", %{
      professional: professional,
      patient: patient
    } do
      insert_pending_job!(professional, patient)
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      before_snapshot = state_snapshot()

      assert {:ok, %Answer{outcome: :stale}} = Live.answer(professional, patient.id, "q", [])

      assert state_snapshot() == before_snapshot
    end
  end

  # --- 5.4 tombstone exclusion ------------------------------------------------------

  describe "answer/4 — a tombstoned resource is never cited" do
    test "a chunk whose resource has been legally deleted is excluded, orphan chunk still present",
         %{
           professional: professional,
           patient: patient
         } do
      resource_id =
        insert_chunk!(
          professional,
          patient,
          "El paciente reporta mejoria del animo",
          near_vector()
        )

      insert_tombstone!(patient, "clinical_note", resource_id)

      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "animo", [])

      # the chunk row itself is untouched — the exclusion happens at
      # query time in `Consultation.Live`, never by mutating `Chunk`.
      assert Repo.get_by(Chunk, source_resource_id: resource_id)
    end

    test "a tombstoned chunk is excluded while a live sibling chunk is still cited", %{
      professional: professional,
      patient: patient
    } do
      tombstoned_id =
        insert_chunk!(
          professional,
          patient,
          "El paciente reporta mejoria del animo",
          near_vector()
        )

      insert_tombstone!(patient, "clinical_note", tombstoned_id)

      live_id =
        insert_chunk!(professional, patient, "El paciente reporta mejoria semanal", near_vector())

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok, %{synthesis: "sintesis"}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: sources}} =
               Live.answer(professional, patient.id, "animo", [])

      returned_resource_ids = Enum.map(sources, & &1.reference.resource_id)
      refute tombstoned_id in returned_resource_ids
      assert returned_resource_ids == [live_id]
    end
  end

  # --- 5.5 freshness hard gate — race re-check (AD9) -------------------------------

  describe "answer/4 — freshness is a hard gate even when the pre-gate already passed" do
    test "an outbox job enqueued between the pre-gate and search/4's own snapshot yields :stale",
         %{professional: professional, patient: patient} do
      insert_chunk!(professional, patient, "El paciente reporta mejoria del animo", near_vector())

      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      Alethea.AI.EmbeddingsMock
      |> stub(:embed, fn _query, [] ->
        # Simulate the enqueue-during-search race (AD9): by the time
        # `Retrieval.search/4` reaches its own freshness snapshot, an
        # outbox job appeared that did NOT exist when `Live`'s pre-gate
        # `Retrieval.freshness/1` call ran a moment earlier.
        insert_pending_job!(professional, patient)
        {:ok, near_vector()}
      end)
      |> stub(:dimensions, fn -> 1024 end)
      |> stub(:model, fn -> "fake-embeddings-bge-m3" end)

      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      assert {:ok, %Answer{outcome: :stale, pending: 1, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "animo", [])
    end
  end

  # --- fixtures ----------------------------------------------------------------

  defp near_vector, do: [1.0 | List.duplicate(0.0, 1023)]
  defp far_vector, do: [0.0, 1.0 | List.duplicate(0.0, 1022)]

  defp stub_query_embedding(vector) do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)

    Alethea.AI.EmbeddingsMock
    |> stub(:embed, fn _query, [] -> {:ok, vector} end)
    |> stub(:dimensions, fn -> 1024 end)
    |> stub(:model, fn -> "fake-embeddings-bge-m3" end)
  end

  defp expect_embeddings_never_called do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)

    expect(Alethea.AI.EmbeddingsMock, :embed, 0, fn _query, [] -> :never end)
  end

  defp insert_tombstone!(patient, resource_type, resource_id) do
    {:ok, tombstone} =
      %Tombstone{}
      |> Tombstone.changeset(%{
        resource_type: resource_type,
        resource_id: resource_id,
        patient_id: patient.id,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        trigger: "manual"
      })
      |> Repo.insert()

    tombstone
  end

  # Audit logging (`AuditLog` KEK_LOAD entries) is a deliberate side
  # effect of legitimate key access, not a mutation of clinical state —
  # excluded from this snapshot on purpose. Only clinical content
  # (`Chunk`) and outbox scheduling (`Oban.Job`) must stay untouched.
  defp state_snapshot do
    %{
      chunks: Repo.all(Chunk),
      oban_jobs: Repo.all(Oban.Job)
    }
  end

  defp insert_pending_job!(professional, patient) do
    {:ok, _job} =
      %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }
      |> ClinicalRecordOutboxWorker.new()
      |> Oban.insert()
  end

  defp insert_chunk!(professional, patient, text, vector) do
    resource_id = Ecto.UUID.generate()
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    attrs = [
      %{
        source_resource_type: "clinical_note",
        source_resource_id: resource_id,
        chunk_index: 0,
        encrypted_content: ciphertext,
        embedding: vector,
        embedding_model: "fake-embeddings-bge-m3",
        token_count: 10,
        full_event: true,
        source_occurred_at: DateTime.utc_now(),
        patient_id: patient.id,
        professional_id: professional.id
      }
    ]

    {:ok, _rows} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)
    resource_id
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "consultation-live-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Consultation Live"
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
