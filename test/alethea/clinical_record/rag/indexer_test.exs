defmodule Alethea.ClinicalRecord.Rag.IndexerTest do
  @moduledoc """
  Tests for `Alethea.ClinicalRecord.Rag.Indexer`
  (sdd/clinical-rag-projection, GitHub #196, WU2/PR2, Phase 3 tasks
  3.1-3.10).

  `eligibility/1` mirrors the spec's "Ingest Eligibility by Event Type"
  table exactly (one clause per row) plus the tombstone-seam catch-all
  (design section 3: `#197` adds a clause here with zero restructuring;
  an unrecognized future event is classified `{:unknown, event}`, never
  a crash).

  `chunk/1` implements the design's chunking heuristic: tokens ≈
  `words * 1.35`, a ~500-token soft budget, paragraph (`\\n{2,}`) then
  sentence (`(?<=[.!?…])\\s+`) boundaries, greedy packing, and ~15%
  trailing overlap between adjacent sub-chunks.
  """
  # async: false — every test here swaps the global `:ai_embeddings` adapter
  # slot through `Application.put_env/3`, so running concurrently with any
  # other file that reads or writes that slot makes both flaky. Same reason
  # `Alethea.AI.AdapterDiscoveryTest` and `Alethea.AITest` are sync.
  use Alethea.DataCase, async: false

  import Mox

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.ClinicalRecord.Rag.{Chunk, Indexer}
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  setup :verify_on_exit!

  describe "eligibility/1 — indexable events (spec table)" do
    test "clinical_note_created indexes" do
      assert Indexer.eligibility("clinical_note_created") == {:index, :clinical_note}
    end

    test "consultation_evidence_created indexes" do
      assert Indexer.eligibility("consultation_evidence_created") ==
               {:index, :consultation_evidence}
    end

    test "clinician_observation_created indexes" do
      assert Indexer.eligibility("clinician_observation_created") ==
               {:index, :clinician_observation}
    end

    test "clinician_observation_updated indexes (replace prior chunks)" do
      assert Indexer.eligibility("clinician_observation_updated") ==
               {:index, :clinician_observation}
    end

    test "ai_proposal_accepted indexes" do
      assert Indexer.eligibility("ai_proposal_accepted") == {:index, :ai_proposal}
    end

    test "functional_analysis_draft_saved indexes (replace prior chunks)" do
      assert Indexer.eligibility("functional_analysis_draft_saved") ==
               {:index, :functional_analysis_draft}
    end

    test "patient_message_received indexes (sdd/telegram-rag-ingestion-262 #262, Slice 1)" do
      assert Indexer.eligibility("patient_message_received") == {:index, :patient_message}
    end
  end

  describe "eligibility/1 — recognized but ignored (spec table)" do
    test "ai_proposal_edited is never indexed (not yet accepted)" do
      assert Indexer.eligibility("ai_proposal_edited") == {:ignore, :not_accepted}
    end

    test "ai_proposal_discarded is never indexed" do
      assert Indexer.eligibility("ai_proposal_discarded") == {:ignore, :not_accepted}
    end

    test "target_behavior_created is structural metadata, not chunked" do
      assert Indexer.eligibility("target_behavior_created") == {:ignore, :structural_metadata}
    end
  end

  describe "eligibility/1 — tombstone seam (unknown future events, #197)" do
    test "an unrecognized event classifies as :unknown instead of crashing" do
      assert Indexer.eligibility("clinical_record_deleted") ==
               {:unknown, "clinical_record_deleted"}
    end

    test "a second unrecognized event value also classifies as :unknown (triangulation)" do
      assert Indexer.eligibility("some_future_event") == {:unknown, "some_future_event"}
    end
  end

  describe "chunk/1 — short event yields a single chunk" do
    test "text under ~500 tokens produces exactly one full-event chunk" do
      text = "Paciente refiere mejoría en el estado de ánimo tras la última sesión."

      assert [chunk] = Indexer.chunk(text)
      assert chunk.chunk_index == 0
      assert chunk.full_event == true
      assert chunk.text == text
      assert chunk.token_count > 0
    end

    test "a different short text (triangulation) still yields one chunk with matching text" do
      text = "Se registra un evento aislado sin mayor detalle clínico."

      assert [chunk] = Indexer.chunk(text)
      assert chunk.chunk_index == 0
      assert chunk.full_event == true
      assert chunk.text == text
    end
  end

  describe "chunk/1 — long event sub-splits with overlap" do
    test "text over ~500 tokens produces 2+ chunks, each carrying a distinct index, with shared trailing overlap" do
      # ~700 tokens (~520 words at the 1.35 tokens/word heuristic),
      # built from repeated distinct sentences so overlap text is
      # detectable by exact substring membership.
      sentences =
        for n <- 1..90 do
          "Este es el enunciado clínico número #{n} sobre la evolución del paciente."
        end

      text = Enum.join(sentences, " ")

      chunks = Indexer.chunk(text)

      assert length(chunks) >= 2
      assert Enum.all?(chunks, &(&1.full_event == false))
      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1))

      Enum.each(chunks, fn c -> assert c.token_count > 0 end)

      # Adjacent chunks overlap: the tail of chunk N reappears at the
      # head of chunk N+1.
      [first, second | _] = chunks
      overlap_candidate = first.text |> String.split(" ") |> Enum.take(-3) |> Enum.join(" ")
      assert second.text =~ overlap_candidate
    end
  end

  describe "embed_chunks/1 — batch embed + dimension guard" do
    setup do
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      :ok
    end

    test "returns one vector per chunk text, in order, when dimensions match" do
      texts = ["primero", "segundo"]

      Alethea.AI.EmbeddingsMock
      |> expect(:embed, fn ^texts, [] ->
        {:ok, [List.duplicate(0.1, 1024), List.duplicate(0.2, 1024)]}
      end)
      |> expect(:dimensions, fn -> 1024 end)

      assert {:ok, [v1, v2]} = Indexer.embed_chunks(texts)
      assert length(v1) == 1024
      assert length(v2) == 1024
    end

    test "cancels with an embedding_dimension_mismatch tuple when a vector's length disagrees with dimensions/0" do
      texts = ["solo uno"]

      Alethea.AI.EmbeddingsMock
      |> expect(:embed, fn ^texts, [] -> {:ok, [List.duplicate(0.1, 384)]} end)
      |> expect(:dimensions, fn -> 1024 end)

      assert {:cancel, {:embedding_dimension_mismatch, 384, 1024}} =
               Indexer.embed_chunks(texts)
    end

    test "cancels before pairing when the adapter returns fewer vectors than chunk texts" do
      texts = ["primero", "segundo"]

      Alethea.AI.EmbeddingsMock
      |> expect(:embed, fn ^texts, [] -> {:ok, [List.duplicate(0.1, 1024)]} end)

      assert {:cancel, {:embedding_batch_size_mismatch, 1, 2}} =
               Indexer.embed_chunks(texts)
    end
  end

  describe "replace_chunks/2 — idempotent transaction" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "inserts a fresh chunk set for a resource that has none yet", %{
      professional: professional,
      patient: patient
    } do
      resource_id = Ecto.UUID.generate()
      attrs = [chunk_attrs(patient, professional, resource_id, 0)]

      assert {:ok, [chunk]} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)
      assert chunk.source_resource_id == resource_id
      assert Alethea.Repo.aggregate(Chunk, :count) == 1
    end

    test "retrying the same resource converges to one chunk set (no duplicates)", %{
      professional: professional,
      patient: patient
    } do
      resource_id = Ecto.UUID.generate()
      attrs = [chunk_attrs(patient, professional, resource_id, 0)]

      assert {:ok, _} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)
      assert {:ok, _} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)

      assert Alethea.Repo.aggregate(Chunk, :count) == 1
    end

    test "re-saving with a different chunk count replaces the old set entirely", %{
      professional: professional,
      patient: patient
    } do
      resource_id = Ecto.UUID.generate()
      first_attrs = [chunk_attrs(patient, professional, resource_id, 0)]

      second_attrs = [
        chunk_attrs(patient, professional, resource_id, 0),
        chunk_attrs(patient, professional, resource_id, 1)
      ]

      assert {:ok, _} = Indexer.replace_chunks({"clinical_note", resource_id}, first_attrs)
      assert {:ok, _} = Indexer.replace_chunks({"clinical_note", resource_id}, second_attrs)

      assert Alethea.Repo.aggregate(Chunk, :count) == 2
    end
  end

  describe "index_event/1 — end to end" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "clinical_note_created produces a retrievable chunk for the note", %{
      professional: professional,
      patient: patient
    } do
      note = insert_clinical_note!(professional, patient, "El paciente relata avances notables.")

      args = %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => note.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(args)

      chunks =
        Chunk
        |> Alethea.Repo.all()
        |> Enum.filter(&(&1.source_resource_id == note.id))

      assert length(chunks) == 1
      assert hd(chunks).patient_id == patient.id
      assert hd(chunks).embedding_model == Alethea.AI.embeddings().model()
    end

    test "target_behavior_created (ignore-with-reason) returns :ok and creates no chunk", %{
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

      assert :ok = Indexer.index_event(args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end

    test "a mismatched embedding batch persists no partial chunk set", %{
      professional: professional,
      patient: patient
    } do
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      body =
        for n <- 1..90, into: "" do
          "Este es el enunciado clínico número #{n} sobre la evolución del paciente. "
        end

      note = insert_clinical_note!(professional, patient, body)

      Alethea.AI.EmbeddingsMock
      |> expect(:embed, fn texts, [] ->
        assert length(texts) > 1
        {:ok, [List.duplicate(0.1, 1024)]}
      end)

      args = %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => note.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert {:cancel, {:embedding_batch_size_mismatch, 1, _expected}} = Indexer.index_event(args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end

    test "an unrecognized event returns :ok without raising (tombstone seam)", %{
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

      assert :ok = Indexer.index_event(args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end

    test "re-processing the same clinical_note_created job (retry) converges to one chunk set", %{
      professional: professional,
      patient: patient
    } do
      note = insert_clinical_note!(professional, patient, "Texto estable para reintento.")

      args = %{
        "event" => "clinical_note_created",
        "resource_type" => "clinical_note",
        "resource_id" => note.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(args)
      assert :ok = Indexer.index_event(args)

      chunks =
        Chunk
        |> Alethea.Repo.all()
        |> Enum.filter(&(&1.source_resource_id == note.id))

      assert length(chunks) == 1
    end

    test "consultation_evidence_created produces a retrievable chunk", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      evidence =
        insert_consultation_evidence!(
          professional,
          patient,
          target_behavior,
          "El paciente cita textualmente su malestar en la sesión anterior."
        )

      args = %{
        "event" => "consultation_evidence_created",
        "resource_type" => "consultation_evidence",
        "resource_id" => evidence.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(args)

      chunks =
        Chunk |> Alethea.Repo.all() |> Enum.filter(&(&1.source_resource_id == evidence.id))

      assert length(chunks) == 1
      assert hd(chunks).target_behavior_id == target_behavior.id
    end

    test "clinician_observation_created produces a retrievable chunk", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, observation} =
        Alethea.ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Observación directa del profesional sobre la conducta objetivo."
        )

      args = %{
        "event" => "clinician_observation_created",
        "resource_type" => "clinician_observation",
        "resource_id" => observation.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(args)

      chunks =
        Chunk |> Alethea.Repo.all() |> Enum.filter(&(&1.source_resource_id == observation.id))

      assert length(chunks) == 1
    end

    test "clinician_observation_updated replaces the prior chunk set for the same resource", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, observation} =
        Alethea.ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Texto original de la observación."
        )

      created_args = %{
        "event" => "clinician_observation_created",
        "resource_type" => "clinician_observation",
        "resource_id" => observation.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(created_args)

      {:ok, _updated} =
        Alethea.ClinicalRecord.update_clinician_observation(
          professional,
          patient.id,
          observation.id,
          "Texto revisado y ampliado de la observación."
        )

      updated_args = %{created_args | "event" => "clinician_observation_updated"}
      assert :ok = Indexer.index_event(updated_args)

      chunks =
        Chunk |> Alethea.Repo.all() |> Enum.filter(&(&1.source_resource_id == observation.id))

      assert length(chunks) == 1
    end

    test "ai_proposal_accepted produces a retrievable chunk", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      proposal =
        insert_accepted_ai_proposal!(
          professional,
          patient,
          target_behavior,
          "Se identifica un patrón de evitación ante situaciones sociales."
        )

      args = %{
        "event" => "ai_proposal_accepted",
        "resource_type" => "ai_proposal",
        "resource_id" => proposal.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(args)

      chunks = Chunk |> Alethea.Repo.all() |> Enum.filter(&(&1.source_resource_id == proposal.id))

      assert length(chunks) == 1
    end

    test "functional_analysis_draft_saved produces a retrievable chunk", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, draft} =
        Alethea.ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Análisis funcional preliminar de la conducta objetivo."
        )

      args = %{
        "event" => "functional_analysis_draft_saved",
        "resource_type" => "functional_analysis_draft",
        "resource_id" => draft.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert :ok = Indexer.index_event(args)

      chunks = Chunk |> Alethea.Repo.all() |> Enum.filter(&(&1.source_resource_id == draft.id))

      assert length(chunks) == 1
    end
  end

  describe "index_event/1 — patient_message (sdd/telegram-rag-ingestion-262 #262, Slice 1)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "patient_message_received produces a chunk decrypted under the patient DEK, with no behavior link",
         %{professional: professional, patient: patient} do
      plaintext = "Me siento mejor esta semana, dormi bien."
      {:ok, message} = Clinical.save_message(patient, plaintext, nil, "inbound", "spontaneous")

      args = patient_message_args(message, patient, professional)

      assert :ok = Indexer.index_event(args)

      chunks = Chunk |> Repo.all() |> Enum.filter(&(&1.source_resource_id == message.id))
      assert length(chunks) == 1
      chunk = hd(chunks)

      assert chunk.source_resource_type == "patient_message"
      assert chunk.target_behavior_id == nil
      assert chunk.source_occurred_at == to_usec(message.timestamp)

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
      assert {:ok, ^plaintext} = PatientVault.decrypt(chunk.encrypted_content, patient_dek)
    end

    test "a resource_id that no longer resolves to a Message surfaces :not_found (worker remaps to :cancel, same as every other resource kind)",
         %{
           professional: professional,
           patient: patient
         } do
      args = %{
        "event" => "patient_message_received",
        "resource_type" => "patient_message",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      assert {:error, :not_found} = Indexer.index_event(args)
      assert Repo.aggregate(Chunk, :count) == 0
    end

    test "chunk ciphertext is opaque: raw SELECT on clinical_record_rag_chunks returns binary, not plaintext (AC2)",
         %{professional: professional, patient: patient} do
      plaintext = "Contenido sensible del paciente que nunca debe verse en claro."
      {:ok, message} = Clinical.save_message(patient, plaintext, nil, "inbound", "spontaneous")

      args = patient_message_args(message, patient, professional)
      assert :ok = Indexer.index_event(args)

      %{rows: [[ciphertext]]} =
        Repo.query!(
          "SELECT encrypted_content FROM clinical_record_rag_chunks WHERE source_resource_id = $1::text::uuid",
          [message.id]
        )

      assert is_binary(ciphertext)
      refute ciphertext == plaintext
      refute String.contains?(ciphertext, plaintext)
    end

    test "re-processing the same patient_message_received job (retry) converges to one chunk set",
         %{professional: professional, patient: patient} do
      {:ok, message} =
        Clinical.save_message(
          patient,
          "Texto estable para reintento.",
          nil,
          "inbound",
          "spontaneous"
        )

      args = patient_message_args(message, patient, professional)

      assert :ok = Indexer.index_event(args)
      assert :ok = Indexer.index_event(args)

      chunks = Chunk |> Repo.all() |> Enum.filter(&(&1.source_resource_id == message.id))
      assert length(chunks) == 1
    end
  end

  describe "eligibility/1 — tombstone classification (sdd/clinical-record-retention #197, task 3.8)" do
    test "clinical_record_legally_deleted classifies as a tombstone purge, not an index or ignore" do
      assert Indexer.eligibility("clinical_record_legally_deleted") ==
               {:tombstone, :legal_deletion}
    end
  end

  describe "index_event/1 — tombstone purge branch (D5, sdd/clinical-record-retention #197, task 3.8)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "purges every existing chunk for the resource and never reaches the Professional/Patient/KEK/DEK lookup",
         %{professional: professional, patient: patient} do
      resource_id = Ecto.UUID.generate()
      attrs = [chunk_attrs(patient, professional, resource_id, 0)]
      assert {:ok, _} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)
      assert Alethea.Repo.aggregate(Chunk, :count) == 1

      args = %{
        "event" => "clinical_record_legally_deleted",
        "resource_type" => "clinical_note",
        "resource_id" => resource_id,
        # A `patient_id`/`professional_id` that resolve to no row at
        # all — if the purge branch ever reached `Repo.get(Professional,
        # ...)` / `Repo.get(Patient, ...)` (the KEK/DEK ladder's entry
        # point in `index_resource/5`), this would return `{:cancel,
        # :not_found}` instead of `:ok`. Structural proof the purge
        # branch short-circuits before any decrypt attempt.
        "patient_id" => Ecto.UUID.generate(),
        "professional_id" => Ecto.UUID.generate()
      }

      assert :ok = Indexer.index_event(args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end

    test "a tombstone event for a resource with no existing chunks is a no-op success" do
      args = %{
        "event" => "clinical_record_legally_deleted",
        "resource_type" => "target_behavior",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => Ecto.UUID.generate(),
        "professional_id" => Ecto.UUID.generate()
      }

      assert :ok = Indexer.index_event(args)
      assert Alethea.Repo.aggregate(Chunk, :count) == 0
    end
  end

  describe "index_event/1 — dual-read by source encryption_version (D1/AD1, sdd/clinical-record-retention #197)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)
      %{professional: professional, patient: patient}
    end

    test "a v1-encrypted (shared patient DEK) source row and a v2-encrypted (CR-scoped DEK) source row both index into decryptable chunks",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)

      {:ok, v1_ciphertext} =
        PatientVault.encrypt("Observacion legada cifrada con la DEK compartida", patient_dek)

      v1_observation =
        %Alethea.ClinicalRecord.ClinicianObservation{}
        |> Alethea.ClinicalRecord.ClinicianObservation.changeset(%{
          encrypted_body: v1_ciphertext,
          encryption_version: 1,
          occurred_at: DateTime.utc_now(),
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: target_behavior.id
        })
        |> Alethea.Repo.insert!()

      # `add_clinician_observation/4` now always stamps `encryption_version:
      # 2` (task 2.8) — a genuinely new, CR-key-encrypted row.
      {:ok, v2_observation} =
        Alethea.ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Observacion nueva cifrada con la DEK de ClinicalRecord"
        )

      assert v2_observation.encryption_version == 2

      v1_args = %{
        "event" => "clinician_observation_created",
        "resource_type" => "clinician_observation",
        "resource_id" => v1_observation.id,
        "patient_id" => patient.id,
        "professional_id" => professional.id
      }

      v2_args = %{v1_args | "resource_id" => v2_observation.id}

      assert :ok = Indexer.index_event(v1_args)
      assert :ok = Indexer.index_event(v2_args)

      {:ok, clinical_record_dek} = Accounts.load_clinical_record_dek(patient, kek)

      v1_chunk =
        Chunk |> Alethea.Repo.all() |> Enum.find(&(&1.source_resource_id == v1_observation.id))

      v2_chunk =
        Chunk |> Alethea.Repo.all() |> Enum.find(&(&1.source_resource_id == v2_observation.id))

      assert v1_chunk.encryption_version == 1
      assert v2_chunk.encryption_version == 2

      assert {:ok, "Observacion legada cifrada con la DEK compartida"} =
               PatientVault.decrypt(v1_chunk.encrypted_content, patient_dek)

      assert {:ok, "Observacion nueva cifrada con la DEK de ClinicalRecord"} =
               PatientVault.decrypt(v2_chunk.encrypted_content, clinical_record_dek)
    end
  end

  defp patient_message_args(%Message{} = message, patient, professional) do
    %{
      "event" => "patient_message_received",
      "resource_type" => "patient_message",
      "resource_id" => message.id,
      "patient_id" => patient.id,
      "professional_id" => professional.id
    }
  end

  # Mirrors `Indexer`'s private `to_usec/1` widening (AD4): the test
  # asserts against the SAME transformation the production code applies,
  # not a re-derivation, so this stays byte-for-byte identical.
  defp to_usec(%DateTime{microsecond: {value, _precision}} = dt) do
    %{dt | microsecond: {value, 6}}
  end

  defp chunk_attrs(patient, professional, resource_id, chunk_index) do
    %{
      source_resource_type: "clinical_note",
      source_resource_id: resource_id,
      chunk_index: chunk_index,
      encrypted_content: <<1, 2, 3>>,
      embedding: List.duplicate(0.1, 1024),
      embedding_model: "fake-embeddings-bge-m3",
      token_count: 10,
      full_event: true,
      source_occurred_at: DateTime.utc_now(),
      patient_id: patient.id,
      professional_id: professional.id
    }
  end

  defp insert_clinical_note!(professional, patient, body) do
    {:ok, note} = Alethea.ClinicalRecord.create_clinical_note(professional, patient.id, body)
    note
  end

  defp create_target_behavior!(professional, patient) do
    {:ok, target_behavior} =
      Alethea.ClinicalRecord.create_target_behavior(
        professional,
        patient.id,
        "Conducta objetivo #{System.unique_integer([:positive])}"
      )

    target_behavior
  end

  defp insert_consultation_evidence!(professional, patient, target_behavior, excerpt) do
    {:ok, evidence} =
      Alethea.ClinicalRecord.add_consultation_evidence(
        professional,
        patient.id,
        target_behavior.id,
        %{
          source_kind: "clinical_note",
          source_id: Ecto.UUID.generate(),
          excerpt: excerpt,
          occurred_at: DateTime.utc_now()
        }
      )

    evidence
  end

  defp insert_accepted_ai_proposal!(professional, patient, target_behavior, text) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    {:ok, proposal} =
      %Alethea.ClinicalRecord.AIProposal{}
      |> Alethea.ClinicalRecord.AIProposal.changeset(%{
        encrypted_original_text: ciphertext,
        encrypted_text: ciphertext,
        model_version: "phi-4-mini",
        occurred_at: DateTime.utc_now(),
        patient_id: patient.id,
        professional_id: professional.id,
        target_behavior_id: target_behavior.id
      })
      |> Alethea.Repo.insert()

    {:ok, accepted} =
      proposal
      |> Alethea.ClinicalRecord.AIProposal.update_changeset(%{status: "accepted"})
      |> Alethea.Repo.update()

    accepted
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "rag-indexer-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Indexer"
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
