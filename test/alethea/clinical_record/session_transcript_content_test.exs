defmodule Alethea.ClinicalRecord.SessionTranscriptContentTest do
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.SessionTranscriptContent

  @sentinel "ALETHEA_SESSION_TRANSCRIPT_SPANS\n"
  @format "alethea.session-transcript-spans"
  @version 1

  @base_span %{start: 0.0, end: 1.5, speaker: "patient", text: "Hello"}

  describe "speakers/0" do
    test "lists the two accepted speaker values" do
      assert SessionTranscriptContent.speakers() == ~w(patient therapist)
    end
  end

  describe "new/1 accepts valid spans" do
    test "accepts spans mixing patient and therapist speakers" do
      spans = [
        @base_span,
        %{start: 1.5, end: 3.0, speaker: "therapist", text: "Hi there"}
      ]

      assert {:ok, %SessionTranscriptContent{spans: ^spans}} = SessionTranscriptContent.new(spans)
    end
  end

  # Table-driven rejection matrix (trim lever, task 2.2): one module attribute
  # plus one `for` comprehension covers every `new/1` rejection case.
  @rejection_cases [
    {"empty transcript", [], :empty_transcript},
    {"unknown speaker string", [%{@base_span | speaker: "psychologist"}], :invalid_speaker},
    {"case-sensitive speaker", [%{@base_span | speaker: "Patient"}], :invalid_speaker},
    {"atom speaker", [%{@base_span | speaker: :patient}], :invalid_speaker},
    {"nil speaker", [%{@base_span | speaker: nil}], :invalid_speaker},
    {"non-number start", [%{@base_span | start: "0"}], :invalid_span},
    {"start after end", [%{@base_span | start: 5.0, end: 1.0}], :invalid_span},
    {"non-binary text", [%{@base_span | text: 123}], :invalid_span},
    {"missing key", [Map.delete(@base_span, :text)], :invalid_span},
    {"extra key", [Map.put(@base_span, :extra, "x")], :invalid_span}
  ]

  for {description, spans, expected_error} <- @rejection_cases do
    @description description
    @spans spans
    @expected_error expected_error

    test "rejects #{@description} with #{inspect(@expected_error)}" do
      assert {:error, @expected_error} = SessionTranscriptContent.new(@spans)
    end
  end

  describe "new/1 whole-transcript rejection (AD1)" do
    test "one bad span at position 40 of 41 rejects the whole list" do
      valid_spans =
        for i <- 0..40 do
          speaker = if rem(i, 2) == 0, do: "patient", else: "therapist"
          %{start: i * 1.0, end: i + 1.0, speaker: speaker, text: "span #{i}"}
        end

      spans = List.update_at(valid_spans, 39, &Map.put(&1, :speaker, "psychologist"))

      assert {:error, :invalid_speaker} = SessionTranscriptContent.new(spans)
    end
  end

  describe "serialize/1" do
    test "emits the sentinel then the exact positional envelope" do
      spans = [
        @base_span,
        %{start: 1.5, end: 3.0, speaker: "therapist", text: "Hi there"}
      ]

      {:ok, content} = SessionTranscriptContent.new(spans)

      expected =
        @sentinel <>
          Jason.encode!([
            @format,
            @version,
            [[0.0, 1.5, "patient", "Hello"], [1.5, 3.0, "therapist", "Hi there"]]
          ])

      assert SessionTranscriptContent.serialize(content) == expected
    end
  end

  describe "serialize |> parse round-trip" do
    test "preserves order, float timestamps, speakers, and Unicode text byte-for-byte" do
      spans = [
        %{start: 0.0, end: 2.25, speaker: "therapist", text: "¿Cómo te sentiste hoy? 😊"},
        %{start: 2.25, end: 2.25, speaker: "patient", text: "line one\nline two"},
        # Overlaps span 2's range (not a transposition — start <= end here).
        %{start: 1.0, end: 2.0, speaker: "patient", text: "overlaps the previous span"}
      ]

      {:ok, content} = SessionTranscriptContent.new(spans)

      assert {:ok, %SessionTranscriptContent{spans: ^spans}} =
               content
               |> SessionTranscriptContent.serialize()
               |> SessionTranscriptContent.parse()
    end
  end

  # Table-driven `parse/1` malformed matrix (trim lever, task 2.6): the
  # "wrong format" and "wrong version" scenarios are collapsed into one row
  # since a single envelope can violate both simultaneously.
  @malformed_bodies [
    {"missing sentinel", "not-a-transcript-body"},
    {"wrong format and version", @sentinel <> Jason.encode!(["alethea.other-format", 99, []])},
    {"non-JSON payload", @sentinel <> "{not-json"},
    {"object instead of array", @sentinel <> Jason.encode!(%{"a" => 1})},
    {"3-element span (missing text)",
     @sentinel <> Jason.encode!([@format, @version, [[0.0, 1.0, "patient"]]])},
    {"bad speaker inside envelope",
     @sentinel <> Jason.encode!([@format, @version, [[0.0, 1.0, "psychologist", "hi"]]])}
  ]

  for {description, body} <- @malformed_bodies do
    @description description
    @body body

    test "parse/1 returns {:error, :malformed} for #{@description}, never raises" do
      assert {:error, :malformed} = SessionTranscriptContent.parse(@body)
    end
  end
end
