defmodule Alethea.ClinicalRecord.Rag.IndexerSessionTranscriptTest do
  @moduledoc """
  Tests for `Alethea.ClinicalRecord.Rag.Indexer.chunk_spans/1`
  (sdd/transcript-rag-ingestion-320, GitHub #320, PR1 — design "Interfaces",
  spec "Chunking is per speaker turn" / "Oversized turns sub-split" /
  "Blank turns are skipped").

  `chunk_spans/1` is a pure, currently-uncalled function in this batch —
  same pattern as WU2's original `Indexer.chunk/1` landing
  (sdd/clinical-rag-projection, GitHub #196): `eligibility/1` still falls
  through to the `:unknown` catch-all for `"session_transcript_created"`,
  so nothing in the live pipeline calls this yet (PR2 wires it).
  """
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.Rag.Indexer

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
end
