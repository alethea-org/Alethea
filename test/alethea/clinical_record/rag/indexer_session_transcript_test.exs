defmodule Alethea.ClinicalRecord.Rag.IndexerSessionTranscriptTest do
  @moduledoc """
  `chunk_spans/1` (pure, PR1) plus PR2's live wiring — `eligibility/1`,
  `fetch_and_decrypt/5`, `pieces_for/2`, `embed_pieces/1` — proved end to end
  via `Indexer.index_event/1` (sdd/transcript-rag-ingestion-320, #320).
  """
  # async: false — some describes swap the global `:ai_embeddings` adapter
  # slot (`RagFixtures` / `Alethea.AI.EmbeddingsMock`), matching `indexer_test.exs`.
  use Alethea.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.Rag.{Chunk, Indexer}
  alias Alethea.ClinicalRecord.SessionTranscript
  alias Alethea.Encryption.PatientVault
  alias Alethea.RagFixtures
  alias Alethea.Repo

  setup :verify_on_exit!

  # Shared by every describe below (pure `chunk_spans/1` describes ignore it).
  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  describe "chunk_spans/1 — one turn yields one chunk (D-A, AC2)" do
    test "3 alternating-speaker non-blank spans produce 3 pieces with matching speaker/start/end" do
      spans = [
        %{start: 0.0, end: 5.0, speaker: "therapist", text: "¿Cómo te sentiste esta semana?"},
        %{start: 5.0, end: 12.0, speaker: "patient", text: "Bastante mejor, gracias."},
        %{start: 12.0, end: 20.0, speaker: "therapist", text: "Me alegra escuchar eso."}
      ]

      pieces = Indexer.chunk_spans(spans)

      assert length(pieces) == 3
      assert Enum.all?(pieces, & &1.full_event)

      assert Enum.map(pieces, & &1.speaker) == ["therapist", "patient", "therapist"]
      assert Enum.map(pieces, & &1.audio_start_seconds) == [0.0, 5.0, 12.0]
      assert Enum.map(pieces, & &1.audio_end_seconds) == [5.0, 12.0, 20.0]

      assert Enum.map(pieces, & &1.text) == [
               "¿Cómo te sentiste esta semana?",
               "Bastante mejor, gracias.",
               "Me alegra escuchar eso."
             ]
    end

    test "a different 2-span transcript (triangulation) still maps each piece to its own span" do
      spans = [
        %{start: 100.0, end: 110.0, speaker: "patient", text: "Empecemos por el sueño."},
        %{start: 110.0, end: 130.0, speaker: "therapist", text: "Cuéntame más sobre eso."}
      ]

      pieces = Indexer.chunk_spans(spans)

      assert length(pieces) == 2
      assert Enum.map(pieces, & &1.speaker) == ["patient", "therapist"]
      assert Enum.map(pieces, & &1.audio_start_seconds) == [100.0, 110.0]
      assert Enum.map(pieces, & &1.audio_end_seconds) == [110.0, 130.0]
    end
  end

  describe "chunk_spans/1 — oversized turns sub-split, all sub-pieces share the parent's bounds (D-A, R-X2)" do
    test "one ~700-token span sub-splits into N>=2 pieces, all sharing speaker/start/end verbatim" do
      # Same construction as `Indexer.chunk/1`'s own oversized test
      # (indexer_test.exs) — ~700 tokens (~520 words at the 1.35
      # tokens/word heuristic), built from repeated distinct sentences.
      sentences =
        for n <- 1..90 do
          "Este es el turno número #{n} sobre la evolución del paciente en la sesión."
        end

      text = Enum.join(sentences, " ")
      spans = [%{start: 10.0, end: 340.0, speaker: "patient", text: text}]

      pieces = Indexer.chunk_spans(spans)

      assert length(pieces) >= 2
      assert Enum.all?(pieces, &(&1.full_event == false))
      assert Enum.all?(pieces, &(&1.speaker == "patient"))
      assert Enum.all?(pieces, &(&1.audio_start_seconds == 10.0))
      assert Enum.all?(pieces, &(&1.audio_end_seconds == 340.0))
    end
  end

  describe "chunk_spans/1 — integer span bounds are normalized to floats (AD1)" do
    test "integer start/end survive as floats on the resulting piece" do
      spans = [%{start: 12, end: 48, speaker: "therapist", text: "Turno con límites enteros."}]

      assert [piece] = Indexer.chunk_spans(spans)

      assert is_float(piece.audio_start_seconds)
      assert is_float(piece.audio_end_seconds)
      assert piece.audio_start_seconds == 12.0
      assert piece.audio_end_seconds == 48.0
    end
  end

  describe "chunk_spans/1 — chunk_index runs globally across all spans, in order (AD5)" do
    test "3 spans, the middle one oversized, still number 0..n-1 across the whole output" do
      sentences =
        for n <- 1..90 do
          "Este es el turno número #{n} sobre la evolución del paciente en la sesión."
        end

      oversized_text = Enum.join(sentences, " ")

      spans = [
        %{start: 0.0, end: 5.0, speaker: "therapist", text: "Primer turno breve."},
        %{start: 5.0, end: 300.0, speaker: "patient", text: oversized_text},
        %{start: 300.0, end: 310.0, speaker: "therapist", text: "Último turno breve."}
      ]

      pieces = Indexer.chunk_spans(spans)

      assert length(pieces) >= 4
      assert Enum.map(pieces, & &1.chunk_index) == Enum.to_list(0..(length(pieces) - 1))
    end
  end

  describe "chunk_spans/1 — blank spans are excluded before chunking (D2)" do
    test "a blank/whitespace-only span between 2 non-blank spans produces only 2 pieces" do
      spans = [
        %{start: 0.0, end: 5.0, speaker: "therapist", text: "Primer turno."},
        %{start: 5.0, end: 8.0, speaker: "patient", text: "   \n\t  "},
        %{start: 8.0, end: 15.0, speaker: "therapist", text: "Segundo turno."}
      ]

      pieces = Indexer.chunk_spans(spans)

      assert length(pieces) == 2
      assert Enum.map(pieces, & &1.text) == ["Primer turno.", "Segundo turno."]
      assert Enum.map(pieces, & &1.chunk_index) == [0, 1]
    end

    test "an all-blank transcript (triangulation) produces zero pieces" do
      spans = [
        %{start: 0.0, end: 1.0, speaker: "patient", text: ""},
        %{start: 1.0, end: 2.0, speaker: "therapist", text: "   "}
      ]

      assert Indexer.chunk_spans(spans) == []
    end
  end

  describe "eligibility/1 — session_transcript_created routes to indexing (AC1)" do
    test "session_transcript_created classifies as {:index, :session_transcript}" do
      assert Indexer.eligibility("session_transcript_created") == {:index, :session_transcript}
    end
  end

  describe "index_event/1 — session_transcript wiring (PR2)" do
    test "non-blank spans persist as v2-encrypted, embedded, float-bounded chunks with no leak, converging idempotently (D2, AD1, AC3, L2-L5)",
         context do
      recorded_at = ~U[2026-05-01 10:00:00.000000Z]
      distinctive_text = "Fragmento inequivoco que jamas debe aparecer en columnas planas."

      {transcript, args} =
        create_transcript!(
          context,
          [
            %{start: 0, end: 5, speaker: "therapist", text: "¿Cómo te sentiste esta semana?"},
            %{start: 5.0, end: 8.0, speaker: "patient", text: "   "},
            %{start: 8.0, end: 15.0, speaker: "patient", text: distinctive_text}
          ],
          recorded_at: recorded_at
        )

      assert :ok = Indexer.index_event(args)

      # D2: the blank span is excluded — 3 spans in, 2 chunks out.
      chunks = chunks_for(transcript.id)
      assert length(chunks) == 2
      assert Enum.map(chunks, & &1.speaker) == ["therapist", "patient"]

      [first, second] = chunks
      # AD1: integer `start: 0, end: 5` survives `insert_all` as floats.
      assert is_float(first.audio_start_seconds) and first.audio_start_seconds == 0.0
      assert is_float(first.audio_end_seconds) and first.audio_end_seconds == 5.0

      {:ok, cr_dek} = clinical_record_dek(context)

      Enum.each(chunks, fn chunk ->
        assert chunk.encryption_version == 2
        assert chunk.source_occurred_at == recorded_at
        assert chunk.target_behavior_id == nil
        assert chunk.embedding_model == Alethea.AI.embeddings().model()
        assert chunk.embedding != nil
      end)

      assert {:ok, "¿Cómo te sentiste esta semana?"} =
               PatientVault.decrypt(first.encrypted_content, cr_dek)

      assert {:ok, ^distinctive_text} = PatientVault.decrypt(second.encrypted_content, cr_dek)

      # No-leak: raw row text never contains span plaintext.
      %{rows: rows} =
        Repo.query!(
          "SELECT t::text FROM clinical_record_rag_chunks t WHERE source_resource_id = $1::text::uuid",
          [transcript.id]
        )

      assert length(rows) == 2
      Enum.each(rows, fn [row_text] -> refute String.contains?(row_text, distinctive_text) end)

      # L2: re-indexing the same transcript converges to the same chunk set.
      assert :ok = Indexer.index_event(args)
      chunks_again = chunks_for(transcript.id)
      assert length(chunks_again) == 2

      texts =
        Enum.map(chunks_again, fn c ->
          {:ok, text} = PatientVault.decrypt(c.encrypted_content, cr_dek)
          text
        end)

      assert texts == ["¿Cómo te sentiste esta semana?", distinctive_text]
    end

    test "a tampered plaintext envelope cancels permanently instead of retrying (AD6)", context do
      {_malformed, malformed_args} = insert_malformed_transcript!(context)
      assert {:cancel, :malformed_transcript} = Indexer.index_event(malformed_args)
    end

    test "therapist-only turns are indexed and their bounds round-trip as floats (D5)", context do
      {therapist_transcript, therapist_args} =
        create_transcript!(context, [
          %{start: 0.0, end: 4.0, speaker: "therapist", text: "Primer comentario."},
          %{start: 12.5, end: 48.75, speaker: "therapist", text: "Turno fraccionario."}
        ])

      assert :ok = Indexer.index_event(therapist_args)
      assert [t1, t2] = chunks_for(therapist_transcript.id)
      assert t1.speaker == "therapist" and t2.speaker == "therapist"
      assert t2.audio_start_seconds == 12.5 and t2.audio_end_seconds == 48.75
    end

    test "a non-transcript clinical_note chunk leaves the three new columns nil", context do
      %{professional: professional, patient: patient} = context

      {:ok, note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Nota sin metadatos.")

      note_args = event_args("clinical_note_created", "clinical_note", note.id, context)
      assert :ok = Indexer.index_event(note_args)
      assert [note_chunk] = chunks_for(note.id)
      assert note_chunk.speaker == nil
      assert note_chunk.audio_start_seconds == nil
      assert note_chunk.audio_end_seconds == nil
    end

    test "an all-blank transcript acks :ok with zero chunks and one scrubbed warning (D2, AD7, R-X1)",
         context do
      RagFixtures.expect_embeddings_never_called()

      {transcript, args} =
        create_transcript!(context, [
          %{start: 0.0, end: 1.0, speaker: "patient", text: ""},
          %{start: 1.0, end: 2.0, speaker: "therapist", text: "   "}
        ])

      log = capture_log(fn -> assert :ok = Indexer.index_event(args) end)

      assert chunks_for(transcript.id) == []
      assert log =~ transcript.id
      refute log =~ "patient"
      refute log =~ "therapist"
      refute log =~ context.patient.id
    end
  end

  # --- shared integration helpers (PR2) ------------------------------------

  defp create_transcript!(ctx, spans, opts \\ []) do
    %{professional: professional, patient: patient} = ctx
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now())

    {:ok, transcript} =
      ClinicalRecord.create_session_transcript(professional, patient.id, %{
        spans: spans,
        recorded_at: recorded_at
      })

    {transcript,
     event_args("session_transcript_created", "session_transcript", transcript.id, ctx)}
  end

  defp insert_malformed_transcript!(%{professional: professional, patient: patient} = ctx) do
    {:ok, cr_dek} = clinical_record_dek(ctx, ensure: true)
    {:ok, ciphertext} = PatientVault.encrypt("not a real transcript envelope", cr_dek)

    {:ok, transcript} =
      %SessionTranscript{}
      |> SessionTranscript.changeset(%{
        encrypted_spans: ciphertext,
        encryption_version: 2,
        recorded_at: DateTime.utc_now(),
        patient_id: patient.id,
        professional_id: professional.id
      })
      |> Repo.insert()

    {transcript,
     event_args("session_transcript_created", "session_transcript", transcript.id, ctx)}
  end

  defp event_args(event, resource_type, resource_id, %{
         professional: professional,
         patient: patient
       }) do
    %{
      "event" => event,
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "patient_id" => patient.id,
      "professional_id" => professional.id
    }
  end

  defp chunks_for(resource_id) do
    Chunk
    |> Repo.all()
    |> Enum.filter(&(&1.source_resource_id == resource_id))
    |> Enum.sort_by(& &1.chunk_index)
  end

  defp clinical_record_dek(%{professional: professional, patient: patient}, opts \\ []) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    if Keyword.get(opts, :ensure, false),
      do: Accounts.ensure_clinical_record_dek(patient, kek),
      else: Accounts.load_clinical_record_dek(patient, kek)
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "rag-transcript-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Rag Transcript"
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
