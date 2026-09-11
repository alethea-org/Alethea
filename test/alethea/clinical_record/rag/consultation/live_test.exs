defmodule Alethea.ClinicalRecord.Rag.Consultation.LiveTest do
  @moduledoc """
  Core outcome mapping for `Alethea.ClinicalRecord.Rag.Consultation.Live`
  (#232a, sdd/grounded-clinical-chat-initial, GitHub #223): authorize
  before any retrieval, freshness as a hard pre-gate, fresh full-history
  retrieval every turn, the evidence sufficiency threshold, and the
  chain's inability to inject or fabricate a source. Isolation, tombstone,
  read-only, and race hardening land in #232b.
  """
  use Alethea.DataCase, async: true
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias Alethea.AI.ClinicalConsultationChainMock
  alias Alethea.ClinicalRecord.Rag.Chunk
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Live, Source}
  alias Alethea.ClinicalRecord.Rag.Indexer
  alias Alethea.ClinicalRecord.Tombstone
  alias Alethea.Encryption.PatientVault
  alias AletheaJobs.ClinicalRecordOutboxWorker

  setup :verify_on_exit!

  # --- 4.1 authorize before retrieve --------------------------------------

  describe "answer/4 — authorize before retrieve" do
    test "a non-treating professional is denied before any embedding or chain call" do
      treating = create_professional!()
      patient = create_patient!(treating)
      stranger = create_professional!()

      # Deliberately NOT stubbed: if `Retrieval.search/4` or the chain's
      # `run/1` were reached, the unstubbed Mox call would raise instead
      # of quietly succeeding — the absence of a crash here IS the proof
      # that authorization short-circuits before any retrieval/synthesis.
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock)
      on_exit(fn -> Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake) end)

      assert {:error, :unauthorized} =
               Live.answer(stranger, patient.id, "¿cómo va el ánimo?", [])
    end
  end

  # --- 4.2 freshness is a hard pre-gate -----------------------------------

  describe "answer/4 — freshness pre-gate (blocks before any decryption)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "a pending outbox job blocks with :stale and never calls the chain", %{
      professional: professional,
      patient: patient
    } do
      insert_pending_job!(professional, patient)

      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock)
      on_exit(fn -> Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake) end)

      assert {:ok, %Answer{outcome: :stale, synthesis: nil, sources: [], pending: 1}} =
               Live.answer(professional, patient.id, "¿cómo va el ánimo?", [])
    end
  end

  # --- 4.3 fresh full-history retrieval every turn ------------------------

  describe "answer/4 — fresh retrieval every turn (no caching, no memoization)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "a second turn sees a chunk indexed after the first turn ran", %{
      professional: professional,
      patient: patient
    } do
      stub(ClinicalConsultationChainMock, :run, fn %{excerpts: excerpts} ->
        {:ok, %{synthesis: "Síntesis con #{length(excerpts)} fragmento(s)."}}
      end)

      stub_query_embedding(near_vector())

      insert_chunk!(professional, patient, "Primera nota clínica relevante", near_vector())

      assert {:ok, %Answer{outcome: :synthesis, sources: [_one]}} =
               Live.answer(professional, patient.id, "consulta", [])

      insert_chunk!(professional, patient, "Segunda nota clínica relevante", near_vector())

      assert {:ok, %Answer{outcome: :synthesis, sources: [_one, _two]}} =
               Live.answer(professional, patient.id, "consulta", [])
    end
  end

  # --- 4.4 resolve_query/2 — pure, history never becomes evidence ---------

  describe "resolve_query/2 — pure, defers follow-up resolution (AD6/AD11)" do
    test "returns the raw query unchanged even for a follow-up phrasing" do
      history = [
        %{role: :professional, content: "¿cómo va el ánimo?"},
        %{role: :assistant, content: "Reporta mejoría sostenida."}
      ]

      assert Live.resolve_query("¿y sobre eso?", history) == "¿y sobre eso?"
    end

    test "uses only role: :professional turns — assistant-only history is a no-op" do
      history = [%{role: :assistant, content: "algo que no debería filtrarse"}]

      resolved = Live.resolve_query("pregunta original", history)

      assert resolved == "pregunta original"
      refute resolved =~ "algo que no debería filtrarse"
    end

    test "empty history resolves to the raw query" do
      assert Live.resolve_query("pregunta", []) == "pregunta"
    end
  end

  # --- 4.5 evidence sufficiency threshold ---------------------------------

  describe "answer/4 — evidence sufficiency threshold (0.35)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "zero indexed chunks yields :no_evidence", %{
      professional: professional,
      patient: patient
    } do
      stub_query_embedding(near_vector())

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "consulta", [])
    end

    test "every result scoring below the threshold yields :no_evidence", %{
      professional: professional,
      patient: patient
    } do
      # Chunk and query embed to orthogonal vectors (cosine distance 1.0,
      # dense component 0.0) with zero lexical overlap — total score ~0.0,
      # well below the 0.35 sufficiency threshold.
      insert_chunk!(
        professional,
        patient,
        "Contenido totalmente ajeno a la consulta",
        near_vector()
      )

      stub_query_embedding(far_vector())

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "zzzzz irrelevante", [])
    end
  end

  # --- 4.6/4.7 synthesis + server-derived sources (no LLM-injected source) -

  describe "answer/4 — at least one sufficient result proceeds to synthesis" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "chain run/1 is called exactly once and the outcome is :synthesis", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, "El paciente reporta mejoría del ánimo", near_vector())
      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn %{question: q, excerpts: [_ | _]} ->
        assert q == "¿cómo va el ánimo?"
        {:ok, %{synthesis: "El paciente reporta una mejoría sostenida del ánimo."}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, synthesis: synthesis, sources: [%Source{}]}} =
               Live.answer(professional, patient.id, "¿cómo va el ánimo?", [])

      assert synthesis == "El paciente reporta una mejoría sostenida del ánimo."
    end

    test "the LLM cannot inject or fabricate a source — sources equal exactly the kept envelope results",
         %{professional: professional, patient: patient} do
      kept_id =
        insert_chunk!(
          professional,
          patient,
          "El paciente reporta mejoría del ánimo",
          near_vector()
        )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok,
         %{
           synthesis:
             "Según la nota clínica #999999 (fabricada), el paciente mejora." <>
               " Fuente inventada: expediente-fantasma-XYZ."
         }}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: [%Source{} = source]}} =
               Live.answer(professional, patient.id, "¿cómo va el ánimo?", [])

      assert source.reference.resource_id == kept_id
      refute source.reference.resource_id == "999999"
      refute source.excerpt =~ "fabricada"
      refute source.excerpt =~ "expediente-fantasma-XYZ"
    end
  end

  # --- 4.8 provider failure is a safe state -------------------------------

  describe "answer/4 — provider failure is a safe state" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      insert_chunk!(professional, patient, "El paciente reporta mejoría del ánimo", near_vector())
      stub_query_embedding(near_vector())
      %{professional: professional, patient: patient}
    end

    test "the chain returning {:error, :unparseable} yields :provider_failure with no leak", %{
      professional: professional,
      patient: patient
    } do
      expect(ClinicalConsultationChainMock, :run, 1, fn _params -> {:error, :unparseable} end)

      assert {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "¿cómo va el ánimo?", [])
    end

    test "the chain raising is caught as a safe :provider_failure, not a crash", %{
      professional: professional,
      patient: patient
    } do
      expect(ClinicalConsultationChainMock, :run, 1, fn _params -> raise "boom" end)

      assert {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "¿cómo va el ánimo?", [])
    end
  end

  # --- 5.1 cross-patient isolation ----------------------------------------

  describe "answer/4 — cross-patient isolation (#232b)" do
    test "consulting patient A never surfaces patient B's chunks, even with identical vectors" do
      professional = create_professional!()
      patient_a = create_patient!(professional)
      patient_b = create_patient!(professional)

      insert_chunk!(
        professional,
        patient_a,
        "Nota clínica exclusiva del paciente A",
        near_vector()
      )

      patient_b_resource_id =
        insert_chunk!(
          professional,
          patient_b,
          "Nota clínica exclusiva del paciente B",
          near_vector()
        )

      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn %{excerpts: excerpts} ->
        {:ok, %{synthesis: "Síntesis con #{length(excerpts)} fragmento(s)."}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: sources}} =
               Live.answer(professional, patient_a.id, "consulta", [])

      refute Enum.any?(sources, &(&1.reference.resource_id == patient_b_resource_id))
      refute Enum.any?(sources, &(&1.excerpt =~ "paciente B"))
    end
  end

  # --- 5.2 cross-tenant isolation ------------------------------------------

  describe "answer/4 — cross-tenant isolation (#232b)" do
    test "a professional's consult never surfaces another professional's patient data" do
      professional_a = create_professional!()
      patient_a = create_patient!(professional_a)
      professional_b = create_professional!()
      patient_b = create_patient!(professional_b)

      insert_chunk!(professional_a, patient_a, "Nota clínica del tenant A", near_vector())

      tenant_b_resource_id =
        insert_chunk!(professional_b, patient_b, "Nota clínica del tenant B", near_vector())

      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn %{excerpts: excerpts} ->
        {:ok, %{synthesis: "Síntesis con #{length(excerpts)} fragmento(s)."}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: sources}} =
               Live.answer(professional_a, patient_a.id, "consulta", [])

      refute Enum.any?(sources, &(&1.reference.resource_id == tenant_b_resource_id))
      refute Enum.any?(sources, &(&1.excerpt =~ "tenant B"))

      # And professional B cannot even reach patient A's id at all.
      assert {:error, :unauthorized} = Live.answer(professional_b, patient_a.id, "consulta", [])
    end
  end

  # --- 5.3 read-only / no-mutation ------------------------------------------

  describe "answer/4 — read-only, no mutation of clinical state (#232b)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      insert_chunk!(professional, patient, "El paciente reporta mejoría del ánimo", near_vector())
      %{professional: professional, patient: patient}
    end

    test "a :synthesis turn leaves chunks and outbox jobs byte-identical", %{
      professional: professional,
      patient: patient
    } do
      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn _params ->
        {:ok, %{synthesis: "Síntesis."}}
      end)

      chunks_before = snapshot(Chunk)
      jobs_before = snapshot(Oban.Job)

      assert {:ok, %Answer{outcome: :synthesis}} =
               Live.answer(professional, patient.id, "consulta", [])

      assert snapshot(Chunk) == chunks_before
      assert snapshot(Oban.Job) == jobs_before
    end

    test "a :no_evidence turn leaves chunks and outbox jobs byte-identical", %{
      professional: professional,
      patient: patient
    } do
      stub_query_embedding(far_vector())

      chunks_before = snapshot(Chunk)
      jobs_before = snapshot(Oban.Job)

      assert {:ok, %Answer{outcome: :no_evidence}} =
               Live.answer(professional, patient.id, "zzzzz irrelevante", [])

      assert snapshot(Chunk) == chunks_before
      assert snapshot(Oban.Job) == jobs_before
    end

    test "a :stale turn (pending outbox job) leaves chunks and outbox jobs byte-identical", %{
      professional: professional,
      patient: patient
    } do
      insert_pending_job!(professional, patient)

      chunks_before = snapshot(Chunk)
      jobs_before = snapshot(Oban.Job)

      assert {:ok, %Answer{outcome: :stale}} =
               Live.answer(professional, patient.id, "consulta", [])

      assert snapshot(Chunk) == chunks_before
      assert snapshot(Oban.Job) == jobs_before
    end

    test "a :provider_failure turn leaves chunks and outbox jobs byte-identical", %{
      professional: professional,
      patient: patient
    } do
      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 1, fn _params -> {:error, :unparseable} end)

      chunks_before = snapshot(Chunk)
      jobs_before = snapshot(Oban.Job)

      assert {:ok, %Answer{outcome: :provider_failure}} =
               Live.answer(professional, patient.id, "consulta", [])

      assert snapshot(Chunk) == chunks_before
      assert snapshot(Oban.Job) == jobs_before
    end
  end

  # --- 5.4 orphan tombstoned chunk exclusion --------------------------------

  describe "answer/4 — tombstoned/orphan chunks are never cited (#232b)" do
    test "a chunk whose resource has a tombstone (legal-deletion job cancelled/discarded) is excluded" do
      professional = create_professional!()
      patient = create_patient!(professional)

      kept_id =
        insert_chunk!(
          professional,
          patient,
          "El paciente reporta mejoría del ánimo",
          near_vector()
        )

      orphan_id =
        insert_chunk!(
          professional,
          patient,
          "Contenido legalmente eliminado que no debe citarse",
          near_vector()
        )

      insert_tombstone!(professional, patient, "clinical_note", orphan_id)
      insert_discarded_job!(professional, patient, orphan_id)

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn %{excerpts: excerpts} ->
        refute Enum.any?(excerpts, &(&1 =~ "legalmente eliminado"))
        {:ok, %{synthesis: "Síntesis con #{length(excerpts)} fragmento(s)."}}
      end)

      assert {:ok, %Answer{outcome: :synthesis, sources: [%Source{} = source]}} =
               Live.answer(professional, patient.id, "consulta", [])

      assert source.reference.resource_id == kept_id
      refute source.reference.resource_id == orphan_id
      refute source.excerpt =~ "legalmente eliminado"
    end

    test "when every kept result is tombstoned, the outcome degrades to :no_evidence" do
      professional = create_professional!()
      patient = create_patient!(professional)

      orphan_id =
        insert_chunk!(
          professional,
          patient,
          "Contenido legalmente eliminado que no debe citarse",
          near_vector()
        )

      insert_tombstone!(professional, patient, "clinical_note", orphan_id)
      insert_discarded_job!(professional, patient, orphan_id)

      stub_query_embedding(near_vector())

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "consulta", [])
    end
  end

  # --- 5.5 freshness is a hard gate with a race re-check (AD9) --------------

  describe "answer/4 — post-retrieval freshness re-check (race, AD9) (#232b)" do
    test "a job enqueued mid-retrieval, after the pre-gate passed, still blocks with :stale" do
      professional = create_professional!()
      patient = create_patient!(professional)
      insert_chunk!(professional, patient, "El paciente reporta mejoría del ánimo", near_vector())

      # The pre-gate `Retrieval.freshness/1` check runs first and passes
      # (no pending job exists yet). The embeddings call happens INSIDE
      # `Retrieval.search/4`, after the pre-gate but before it computes
      # its own envelope freshness — inserting the pending job as a side
      # effect of that call simulates a job enqueued mid-flight (the AD9
      # race). `ClinicalConsultationChainMock` is deliberately NOT
      # stubbed: an unexpected call would raise, proving the chain is
      # never reached.
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      Alethea.AI.EmbeddingsMock
      |> stub(:embed, fn _query, [] ->
        insert_pending_job!(professional, patient)
        {:ok, near_vector()}
      end)
      |> stub(:dimensions, fn -> 1024 end)
      |> stub(:model, fn -> "fake-embeddings-bge-m3" end)

      assert {:ok, %Answer{outcome: :stale, synthesis: nil, sources: [], pending: 1}} =
               Live.answer(professional, patient.id, "consulta", [])
    end
  end

  # --- fixtures ------------------------------------------------------------

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

  # Simulates a legal-deletion outbox job that reached a TERMINAL state
  # outside `Retrieval.freshness/1`'s `@pending_states` (available,
  # scheduled, executing, retryable) — the job that was supposed to
  # purge/reindex `resource_id`'s chunk never completed, but it is no
  # longer pending either, so `freshness/1` correctly reports "not
  # stale" while the orphan chunk remains retrievable. Only the
  # query-time `Tombstone.for_resource/2` cross-check (5.6) can still
  # catch it.
  defp insert_discarded_job!(professional, patient, resource_id) do
    {:ok, job} =
      %{
        "event" => "clinical_note_deleted",
        "resource_type" => "clinical_note",
        "resource_id" => resource_id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }
      |> ClinicalRecordOutboxWorker.new()
      |> Oban.insert()

    {:ok, _discarded} = job |> Ecto.Changeset.change(state: "discarded") |> Repo.update()
  end

  defp insert_tombstone!(professional, patient, resource_type, resource_id) do
    {:ok, tombstone} =
      %Tombstone{}
      |> Tombstone.changeset(%{
        resource_type: resource_type,
        resource_id: resource_id,
        patient_id: patient.id,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        deleted_by_id: professional.id,
        trigger: "manual"
      })
      |> Repo.insert()

    tombstone
  end

  defp snapshot(schema) do
    schema
    |> Repo.all()
    |> Enum.sort_by(& &1.id)
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
        email: "rag-consultation-live-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Consultation"
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
