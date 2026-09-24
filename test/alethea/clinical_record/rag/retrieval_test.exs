defmodule Alethea.ClinicalRecord.Rag.RetrievalTest do
  @moduledoc """
  Tests for `Alethea.ClinicalRecord.Rag.Retrieval`
  (sdd/clinical-rag-projection, GitHub #196, WU4/PR4, Phase 5 tasks
  5.1-5.8).

  No caller wires this module yet (WU5 wires the LiveView) — same
  pattern as WU2's `Indexer`: an independently unit/integration-tested,
  currently-uncalled module.

  Covers, per design section 5:
  - Lexical normalization (NFD accent-fold + Spanish stopwords) and the
    dense/lexical score merge (`0.7 * (1 - dense) + 0.3 * lexical`).
  - `search/4` cross-patient isolation (adversarial query), ranking
    order, and the decrypt-strictly-after-candidate-limit security
    boundary (never decrypt the whole table then cut down).
  - Freshness disclosure from pending/in-flight `oban_jobs`.
  - Authorization via the existing `get_patient_for_professional/2`
    accessor (non-treating professional denied).
  """
  # async: false — every test here swaps the global `:ai_embeddings` adapter
  # slot through `Application.put_env/3`, so running concurrently with any
  # other file that reads or writes that slot makes both flaky. Same reason
  # `Alethea.AI.AdapterDiscoveryTest` and `Alethea.AITest` are sync.
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.Rag.{Chunk, Indexer, Retrieval}
  alias Alethea.Encryption.PatientVault
  alias AletheaJobs.ClinicalRecordOutboxWorker

  setup :verify_on_exit!

  # --- 5.1 lexical normalization ---------------------------------------

  describe "normalize/1 — accent-fold + Spanish stopword removal" do
    test "downcases, strips accents, and drops Spanish stopwords" do
      tokens = Retrieval.normalize("El Paciente ESTÁ mejorando de su ánimo")

      assert "paciente" in tokens
      assert "mejorando" in tokens
      assert "animo" in tokens
      refute "el" in tokens
      refute "su" in tokens
      refute "de" in tokens
    end

    test "a different sentence (triangulation) still folds accents and drops stopwords" do
      tokens = Retrieval.normalize("La conducta se repite según lo observado")

      assert "conducta" in tokens
      assert "repite" in tokens
      assert "segun" in tokens
      assert "observado" in tokens
      refute "la" in tokens
      refute "se" in tokens
      refute "lo" in tokens
    end

    test "punctuation is stripped and does not survive as a token" do
      tokens = Retrieval.normalize("¿Cómo está el paciente? ¡Mejor!")

      assert "paciente" in tokens
      assert "mejor" in tokens
      refute Enum.any?(tokens, &String.contains?(&1, "¿"))
      refute Enum.any?(tokens, &String.contains?(&1, "?"))
    end
  end

  describe "lexical_score/2 — content-token coverage + exact-phrase bonus" do
    test "full query token coverage plus an exact phrase match yields the maximum score" do
      score =
        Retrieval.lexical_score("mejoría del ánimo", "reporta mejoria del animo esta semana")

      assert score > 0.8
      assert score <= 1.0
    end

    test "zero token overlap yields a score of exactly 0.0 (triangulation)" do
      assert Retrieval.lexical_score("evitación social", "cambio de horario de la sesión") == 0.0
    end

    test "partial coverage without the exact phrase yields a score strictly between 0 and 1" do
      score =
        Retrieval.lexical_score("evitación social ansiedad", "refiere ansiedad en la reunión")

      assert score > 0.0
      assert score < 1.0
    end
  end

  describe "merge_score/3 — 0.7*(1-dense) + 0.3*lexical, overridable weights" do
    test "default weights combine dense distance and lexical score" do
      assert_in_delta Retrieval.merge_score(0.0, 1.0), 1.0, 0.0001
      assert_in_delta Retrieval.merge_score(1.0, 0.0), 0.0, 0.0001
      assert_in_delta Retrieval.merge_score(0.0, 0.0), 0.7, 0.0001
      assert_in_delta Retrieval.merge_score(1.0, 1.0), 0.3, 0.0001
    end

    test "weights are overridable via opts without needing a migration (triangulation)" do
      score = Retrieval.merge_score(0.0, 0.0, dense_weight: 0.5, lexical_weight: 0.5)
      assert_in_delta score, 0.5, 0.0001

      score = Retrieval.merge_score(1.0, 1.0, dense_weight: 0.5, lexical_weight: 0.5)
      assert_in_delta score, 0.5, 0.0001
    end
  end

  # --- Affinity scoring and tier badges (GitHub #318) -------------------

  describe "normalize_match_percentage/1 — score to clamped 0..100 integer" do
    test "converts scores between 0 and 1 into integer percentages" do
      assert Retrieval.normalize_match_percentage(0.85) == 85
      assert Retrieval.normalize_match_percentage(1.0) == 100
      assert Retrieval.normalize_match_percentage(0.0) == 0
      assert Retrieval.normalize_match_percentage(0.756) == 76
    end

    test "clamps out-of-range scores to [0, 100]" do
      assert Retrieval.normalize_match_percentage(-0.3) == 0
      assert Retrieval.normalize_match_percentage(1.5) == 100
    end
  end

  describe "affinity_tier/1 and affinity_label/1 — tier thresholds (>75, 50..75, <50)" do
    test "classifies percentage thresholds into :high, :medium, and :low" do
      assert Retrieval.affinity_tier(100) == :high
      assert Retrieval.affinity_tier(76) == :high
      assert Retrieval.affinity_tier(75) == :medium
      assert Retrieval.affinity_tier(50) == :medium
      assert Retrieval.affinity_tier(49) == :low
      assert Retrieval.affinity_tier(0) == :low
    end

    test "classifies float scores <= 1.0" do
      assert Retrieval.affinity_tier(0.82) == :high
      assert Retrieval.affinity_tier(0.75) == :medium
      assert Retrieval.affinity_tier(0.50) == :medium
      assert Retrieval.affinity_tier(0.35) == :low
    end

    test "affinity_label/1 maps tier atom to Spanish label" do
      assert Retrieval.affinity_label(:high) == "Alta afinidad"
      assert Retrieval.affinity_label(:medium) == "Media afinidad"
      assert Retrieval.affinity_label(:low) == "Baja afinidad"
    end
  end

  describe "affinity_badge/1 — structured UI badge envelope" do
    test "returns badge map with tier, label, and percentage" do
      assert Retrieval.affinity_badge(85) == %{
               tier: :high,
               label: "Alta afinidad",
               percentage: 85
             }

      assert Retrieval.affinity_badge(60) == %{
               tier: :medium,
               label: "Media afinidad",
               percentage: 60
             }

      assert Retrieval.affinity_badge(30) == %{
               tier: :low,
               label: "Baja afinidad",
               percentage: 30
             }
    end
  end

  # --- 5.3/5.4 search/4 -------------------------------------------------

  describe "search/4 — cross-patient isolation (adversarial query)" do
    setup do
      professional = create_professional!()
      patient_a = create_patient!(professional)
      patient_b = create_patient!(professional)
      %{professional: professional, patient_a: patient_a, patient_b: patient_b}
    end

    test "a query crafted from patient B's exact content never returns patient B's chunks when searching patient A",
         %{professional: professional, patient_a: patient_a, patient_b: patient_b} do
      secret_b_text = "El paciente B reporta ideación suicida activa y un plan concreto"
      leaked_resource_id = insert_chunk!(professional, patient_b, secret_b_text, near_vector())

      matching_a_id =
        insert_chunk!(
          professional,
          patient_a,
          "Nota rutinaria sobre el paciente A",
          near_vector()
        )

      # Query embeds to the SAME vector as patient B's secret chunk —
      # the strongest possible dense-similarity pull toward the leak —
      # yet the WHERE clause scoping by patient_id must still exclude it.
      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.search(professional, patient_a.id, secret_b_text)

      returned_ids = Enum.map(results, & &1.source_resource_id)
      refute leaked_resource_id in returned_ids
      assert matching_a_id in returned_ids
    end
  end

  describe "search/4 — ranking order (dense + lexical both matter)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "with tied dense distance, the chunk with higher lexical overlap ranks first", %{
      professional: professional,
      patient: patient
    } do
      query = "evitación de situaciones sociales"

      matching_id =
        insert_chunk!(
          professional,
          patient,
          "El paciente presenta evitacion de situaciones sociales recurrente",
          near_vector()
        )

      unrelated_id =
        insert_chunk!(
          professional,
          patient,
          "Se ajusta el horario de la próxima cita",
          near_vector()
        )

      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} = Retrieval.search(professional, patient.id, query)

      ranked_ids = Enum.map(results, & &1.source_resource_id)
      matching_index = Enum.find_index(ranked_ids, &(&1 == matching_id))
      unrelated_index = Enum.find_index(ranked_ids, &(&1 == unrelated_id))

      assert matching_index < unrelated_index
    end
  end

  describe "search/4 — decrypt strictly after the candidate-limit cutoff (security boundary)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "chunks outside the candidate window are never decrypted, even if their ciphertext is corrupt",
         %{professional: professional, patient: patient} do
      # Two "near" chunks (dense distance 0 to the query vector) with
      # genuinely decryptable content, and three "far" chunks (dense
      # distance 1) whose ciphertext is deliberately corrupt. A
      # `candidate_limit` of 2 must select ONLY the near chunks from
      # Postgres before any decryption happens — if the implementation
      # decrypted the whole table first and limited afterward, it would
      # attempt to decrypt the corrupt rows and crash.
      near_id_1 =
        insert_chunk!(professional, patient, "Primera nota cercana a la consulta", near_vector())

      near_id_2 =
        insert_chunk!(professional, patient, "Segunda nota cercana a la consulta", near_vector())

      for _ <- 1..3 do
        insert_corrupt_chunk!(professional, patient, far_vector())
      end

      stub_query_embedding(near_vector())

      assert {:ok, %{results: results, chunk_count: 5}} =
               Retrieval.search(professional, patient.id, "consulta",
                 candidate_limit: 2,
                 limit: 10
               )

      returned_ids = Enum.map(results, & &1.source_resource_id)
      assert Enum.sort(returned_ids) == Enum.sort([near_id_1, near_id_2])
    end
  end

  describe "suggest/4 — evidence candidate defaults and exclusions" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, "evitación social")

      %{professional: professional, patient: patient, target_behavior: target_behavior}
    end

    test "returns at most five results by default", %{
      professional: professional,
      patient: patient
    } do
      for index <- 1..6 do
        insert_chunk!(professional, patient, "Nota relevante #{index}", near_vector())
      end

      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.suggest(professional, patient.id, "nota relevante")

      assert length(results) == 5
    end

    test "blank query returns an empty envelope without embedding", %{
      professional: professional,
      patient: patient
    } do
      deny_query_embedding()

      assert {:ok, %{results: [], chunk_count: 0}} =
               Retrieval.suggest(professional, patient.id, "  \n ")
    end

    test "excludes a chunk dismissed for the target behavior", %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dismissed_resource = insert_chunk!(professional, patient, "Descartada", near_vector())
      kept_resource = insert_chunk!(professional, patient, "Conservada", near_vector())
      dismissed_chunk_id = chunk_id_for_resource!(dismissed_resource)

      assert {:ok, _dismissal} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 dismissed_chunk_id
               )

      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.suggest(professional, patient.id, "nota",
                 target_behavior_id: target_behavior.id
               )

      assert Enum.map(results, & &1.source_resource_id) == [kept_resource]
    end

    test "excludes all chunks from a resource dismissed for the target behavior", %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dismissed_resource = insert_chunk!(professional, patient, "Descartada", near_vector())
      kept_resource = insert_chunk!(professional, patient, "Conservada", near_vector())

      assert {:ok, _dismissal} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{resource_id: dismissed_resource, resource_type: "clinical_note"}
               )

      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.suggest(professional, patient.id, "nota",
                 target_behavior_id: target_behavior.id
               )

      assert Enum.map(results, & &1.source_resource_id) == [kept_resource]
    end

    test "excludes chunk ids passed directly in opts", %{
      professional: professional,
      patient: patient
    } do
      excluded_resource = insert_chunk!(professional, patient, "Excluida", near_vector())
      kept_resource = insert_chunk!(professional, patient, "Conservada", near_vector())
      excluded_chunk_id = chunk_id_for_resource!(excluded_resource)
      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.suggest(professional, patient.id, "nota",
                 exclude_chunk_ids: [excluded_chunk_id]
               )

      assert Enum.map(results, & &1.source_resource_id) == [kept_resource]
    end

    test "filters before the candidate limit and decrypts only the retained window", %{
      professional: professional,
      patient: patient
    } do
      excluded_resource = insert_chunk!(professional, patient, "Excluida", near_vector())
      retained_resource = insert_chunk!(professional, patient, "Cercana", near_vector())
      far_resource = insert_chunk!(professional, patient, "Lejana", far_vector())
      insert_corrupt_chunk!(professional, patient, far_vector())
      excluded_chunk_id = chunk_id_for_resource!(excluded_resource)
      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.suggest(professional, patient.id, "nota",
                 candidate_limit: 2,
                 limit: 10,
                 exclude_chunk_ids: [excluded_chunk_id]
               )

      assert Enum.sort(Enum.map(results, & &1.source_resource_id)) ==
               Enum.sort([retained_resource, far_resource])
    end

    test "preserves cross-patient isolation", %{professional: professional, patient: patient} do
      other_patient = create_patient!(professional)
      own_resource = insert_chunk!(professional, patient, "Propia", near_vector())
      foreign_resource = insert_chunk!(professional, other_patient, "Ajena", near_vector())
      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} =
               Retrieval.suggest(professional, patient.id, "nota")

      result_ids = Enum.map(results, & &1.source_resource_id)
      assert own_resource in result_ids
      refute foreign_resource in result_ids
    end

    test "constrains candidates to specific source channel via source_kind option", %{
      professional: professional,
      patient: patient
    } do
      note_id =
        insert_chunk!(
          professional,
          patient,
          "Nota de sesión presencial",
          near_vector(),
          "clinical_note"
        )

      telegram_id =
        insert_chunk!(
          professional,
          patient,
          "Mensaje de telegram del paciente",
          near_vector(),
          "patient_message"
        )

      session_id =
        insert_chunk!(
          professional,
          patient,
          "Transcripción de sesión grabada",
          near_vector(),
          "session_transcript"
        )

      stub_query_embedding(near_vector())

      assert {:ok, %{results: tg_results}} =
               Retrieval.suggest(professional, patient.id, "paciente", source_kind: :telegram)

      assert Enum.map(tg_results, & &1.source_resource_id) == [telegram_id]

      assert {:ok, %{results: notes_results}} =
               Retrieval.suggest(professional, patient.id, "paciente", source_kind: :notes)

      assert Enum.map(notes_results, & &1.source_resource_id) == [note_id]

      assert {:ok, %{results: session_results}} =
               Retrieval.suggest(professional, patient.id, "paciente", source_kind: :sessions)

      assert Enum.map(session_results, & &1.source_resource_id) == [session_id]

      assert {:ok, %{results: all_results}} =
               Retrieval.suggest(professional, patient.id, "paciente", source_kind: :all)

      all_ids = Enum.map(all_results, & &1.source_resource_id)
      assert note_id in all_ids
      assert telegram_id in all_ids
      assert session_id in all_ids
    end
  end

  # --- 5.5/5.6 freshness -------------------------------------------------

  describe "search/4 — freshness disclosure from pending/in-flight oban_jobs" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "a pending outbox job for the same patient is disclosed as stale", %{
      professional: professional,
      patient: patient
    } do
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

      stub_query_embedding(near_vector())

      assert {:ok, %{freshness: %{stale?: true, pending: 1}}} =
               Retrieval.search(professional, patient.id, "consulta")
    end

    test "no pending outbox jobs for the patient is not stale (triangulation)", %{
      professional: professional,
      patient: patient
    } do
      stub_query_embedding(near_vector())

      assert {:ok, %{freshness: %{stale?: false, pending: 0}}} =
               Retrieval.search(professional, patient.id, "consulta")
    end

    test "a pending job for a DIFFERENT patient does not mark this patient stale", %{
      professional: professional,
      patient: patient
    } do
      other_patient = create_patient!(professional)

      {:ok, _job} =
        %{
          "event" => "clinical_note_created",
          "resource_type" => "clinical_note",
          "resource_id" => Ecto.UUID.generate(),
          "patient_id" => other_patient.id,
          "professional_id" => professional.id
        }
        |> ClinicalRecordOutboxWorker.new()
        |> Oban.insert()

      stub_query_embedding(near_vector())

      assert {:ok, %{freshness: %{stale?: false, pending: 0}}} =
               Retrieval.search(professional, patient.id, "consulta")
    end
  end

  # --- 5.7/5.8 authz ------------------------------------------------------

  describe "search/4 — authorization via get_patient_for_professional/2" do
    test "a non-treating professional is denied" do
      treating = create_professional!()
      patient = create_patient!(treating)
      stranger = create_professional!()

      assert {:error, :unauthorized} = Retrieval.search(stranger, patient.id, "consulta")
    end

    test "a deleted/unknown patient id is denied the same way (triangulation)" do
      professional = create_professional!()

      assert {:error, :unauthorized} =
               Retrieval.search(professional, Ecto.UUID.generate(), "consulta")
    end
  end

  describe "metadata/2 — authorization and page metadata without content access" do
    test "returns chunk count and freshness without embedding or decrypting chunks" do
      professional = create_professional!()
      patient = create_patient!(professional)

      assert {:ok, %{chunk_count: 0, freshness: %{stale?: false, pending: 0}}} =
               Retrieval.metadata(professional, patient.id)
    end

    test "denies a non-treating professional" do
      treating = create_professional!()
      patient = create_patient!(treating)
      stranger = create_professional!()

      assert {:error, :unauthorized} = Retrieval.metadata(stranger, patient.id)
    end
  end

  describe "search/4 — dual-read by chunk encryption_version (D1/AD1, sdd/clinical-record-retention #197)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "a v1-encrypted chunk (shared patient DEK) and a v2-encrypted chunk (CR-scoped DEK) both decrypt in one search/4 call",
         %{professional: professional, patient: patient} do
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      v1_id =
        insert_versioned_chunk!(
          professional,
          patient,
          "Nota antigua cifrada compartida",
          near_vector(),
          patient_dek,
          1
        )

      v2_id =
        insert_versioned_chunk!(
          professional,
          patient,
          "Nota nueva cifrada ClinicalRecord",
          near_vector(),
          clinical_record_dek,
          2
        )

      stub_query_embedding(near_vector())

      assert {:ok, %{results: results}} = Retrieval.search(professional, patient.id, "nota")

      returned = Map.new(results, &{&1.source_resource_id, &1.content})
      assert returned[v1_id] == "Nota antigua cifrada compartida"
      assert returned[v2_id] == "Nota nueva cifrada ClinicalRecord"
    end
  end

  # --- fixtures -----------------------------------------------------------

  defp near_vector, do: [1.0 | List.duplicate(0.0, 1023)]
  defp far_vector, do: [0.0, 1.0 | List.duplicate(0.0, 1022)]

  defp deny_query_embedding do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)
  end

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

  defp insert_chunk!(professional, patient, text, vector) do
    insert_chunk!(professional, patient, text, vector, "clinical_note")
  end

  defp insert_chunk!(professional, patient, text, vector, resource_type) do
    resource_id = Ecto.UUID.generate()
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    attrs = [
      %{
        source_resource_type: resource_type,
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

    {:ok, _rows} = Indexer.replace_chunks({resource_type, resource_id}, attrs)
    resource_id
  end

  defp chunk_id_for_resource!(resource_id) do
    Chunk
    |> Alethea.Repo.get_by!(source_resource_id: resource_id)
    |> Map.fetch!(:id)
  end

  defp insert_versioned_chunk!(professional, patient, text, vector, dek, encryption_version) do
    resource_id = Ecto.UUID.generate()
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    attrs = [
      %{
        source_resource_type: "clinical_note",
        source_resource_id: resource_id,
        chunk_index: 0,
        encrypted_content: ciphertext,
        encryption_version: encryption_version,
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

  defp insert_corrupt_chunk!(professional, patient, vector) do
    resource_id = Ecto.UUID.generate()

    attrs = [
      %{
        source_resource_type: "clinical_note",
        source_resource_id: resource_id,
        chunk_index: 0,
        # Too short to be a valid `iv <> ciphertext <> tag` envelope —
        # `PatientVault.decrypt/2` returns `{:error, :invalid_ciphertext}`
        # for this, which this module treats as a hard failure. It must
        # never be reached when the candidate window excludes this row.
        encrypted_content: <<1, 2, 3>>,
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
        email: "rag-retrieval-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Retrieval"
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
