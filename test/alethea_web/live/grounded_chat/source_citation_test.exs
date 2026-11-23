defmodule AletheaWeb.GroundedChat.SourceCitationTest do
  @moduledoc """
  `SourceCitation.source_to_citation/1` adapts a `%Source{}` into a
  `%Citation{}`. S5 (session recording): a session_transcript retrieval
  result keeps its speaker and audio span through Source → Citation, so
  `citation/1` can show who spoke and when.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Alethea.ClinicalRecord.Rag.Consultation.Source
  alias AletheaWeb.CoreComponents
  alias AletheaWeb.GroundedChat.SourceCitation

  defp result(overrides) do
    Map.merge(
      %{
        chunk_id: "33333333-3333-3333-3333-333333333333",
        source_resource_type: "clinical_note",
        source_resource_id: Ecto.UUID.generate(),
        source_occurred_at: ~U[2026-03-04 10:00:00Z],
        target_behavior_id: nil,
        content: "Hablamos de la semana."
      },
      Map.new(overrides)
    )
  end

  test "a session_transcript retrieval result flows through Source and Citation into the rendered citation" do
    [source] =
      Source.from_results([
        result(
          source_resource_type: "session_transcript",
          speaker: "patient",
          audio_start_seconds: 760.7,
          audio_end_seconds: 785.2
        )
      ])

    citation = SourceCitation.source_to_citation(source)

    assert citation.speaker == "patient"
    assert citation.audio_start_seconds == 760.7
    assert citation.audio_end_seconds == 785.2

    html = render_component(&CoreComponents.citation/1, citation: citation)

    assert html =~ "Sesión grabada"
    assert html =~ "Paciente · min 12:40 – 13:05"
    assert html =~ "Hablamos de la semana."
  end

  test "a non-transcript source keeps nil speaker/time and its existing ref and label" do
    [source] = Source.from_results([result([])])

    citation = SourceCitation.source_to_citation(source)

    assert citation.source_ref == "clinical_note/33333333"
    assert citation.speaker == nil
    assert citation.audio_start_seconds == nil
    assert citation.audio_end_seconds == nil

    html = render_component(&CoreComponents.citation/1, citation: citation)

    assert html =~ "Nota clínica"
    refute html =~ "citation__speaker"
  end
end
