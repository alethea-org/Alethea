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
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Live, Source}
  alias Alethea.ClinicalRecord.Rag.Indexer
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
