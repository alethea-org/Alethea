defmodule AletheaWeb.CoreComponents.CitationTest do
  @moduledoc """
  Coverage for the citation renderer that the Síntesis (A4) and
  Hipótesis (C2) panels both consume (`AletheaWeb.CoreComponents`).

  Specs cover:

    * Collapsed vs. expanded rendering (`<details>`/`<summary>`).
    * The four required fields appear: kind, fecha, ref estable, excerpt.
    * Excerpt verbatim, with HTML escaping (defense against a chunk
      whose decrypted text contains a `<`/`&`/script tag).
    * Stable DOM id derived from `source_ref`, so two cites never
      collide and ARIA labels remain unique.
    * List wrapper renders N cites and an empty state.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Alethea.ClinicalRecord.Rag.Citation
  alias AletheaWeb.CoreComponents

  @valid_result %{
    chunk_id: "11111111-1111-1111-1111-111111111111",
    source_resource_type: "clinical_notes",
    source_resource_id: "22222222-2222-2222-2222-222222222222",
    source_occurred_at: ~U[2026-08-12 14:30:00Z],
    target_behavior_id: nil,
    chunk_index: 0,
    full_event: true,
    content: "El paciente reportó insomnio recurrente durante la última semana.",
    dense_distance: 0.12,
    lexical_score: 0.66,
    score: 0.83
  }

  defp citation(attrs \\ %{}, kind \\ "clinical_notes") do
    result =
      @valid_result
      |> Map.put(:chunk_index, Map.get(attrs, :chunk_index, 0))
      |> Map.put(:source_resource_type, kind)

    Citation.from_retrieval_result(result)
  end

  describe "<.citation> collapsed (default)" do
    test "renders kind, ref and fecha as the summary — excerpt is hidden" do
      html = render_component(&CoreComponents.citation/1, citation: citation())

      assert html =~ "<details"
      refute html =~ "open"

      assert html =~ "clinical_notes"
      assert html =~ Citation.ref(@valid_result)

      assert html =~ "2026-08-12"

      refute html =~ "El paciente reportó insomnio"
    end

    test "uses a stable DOM id derived from the source_ref" do
      c = citation()
      html = render_component(&CoreComponents.citation/1, citation: c)

      assert html =~ "id=\"citation-#{c.source_ref}\""
    end

    test "marks the summary as a button-equivalent control for ARIA" do
      html = render_component(&CoreComponents.citation/1, citation: citation())

      assert html =~ "<summary"
      assert html =~ "aria-controls=\"citation-#{citation().source_ref}\""
    end
  end

  describe "<.citation> expanded" do
    test "expands by default when the `expanded` attribute is true" do
      c = citation()
      html = render_component(&CoreComponents.citation/1, citation: c, expanded: true)

      assert html =~ "<details"
      assert html =~ " open"
      assert html =~ "El paciente reportó insomnio recurrente"
    end

    test "aria-expanded reflects the open state" do
      html = render_component(&CoreComponents.citation/1, citation: citation(), expanded: true)
      assert html =~ "aria-expanded=\"true\""

      html2 = render_component(&CoreComponents.citation/1, citation: citation())
      assert html2 =~ "aria-expanded=\"false\""
    end
  end

  describe "verbatim excerpt + escape" do
    test "renders the excerpt exactly as stored by the retrieve (server-derived)" do
      html = render_component(&CoreComponents.citation/1, citation: citation(), expanded: true)
      assert html =~ "El paciente reportó insomnio recurrente durante la última semana."
    end

    test "escapes HTML special characters — no script injection through excerpt" do
      c =
        @valid_result
        |> Map.put(:content, "<script>alert(1)</script> & 'quoted'")
        |> Citation.from_retrieval_result()

      html = render_component(&CoreComponents.citation/1, citation: c, expanded: true)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"

      assert html =~ "&amp;"

      assert html =~ "&#39;quoted&#39;"
    end
  end

  describe "<.citation_list>" do
    test "renders one citation per item in the list" do
      c1 = citation()
      c2 = citation(%{chunk_index: 1})
      html = render_component(&CoreComponents.citation_list/1, citations: [c1, c2])

      assert html =~ "id=\"citation-#{c1.source_ref}\""
      assert html =~ "id=\"citation-#{c2.source_ref}\""
    end

    test "renders nothing for an empty list — no decorative chrome" do
      html = render_component(&CoreComponents.citation_list/1, citations: [])

      assert html =~ "<section"
      refute html =~ "<details"
    end

    test "shares the same DOM shape for every kind (no divergent rendering per source type)" do
      c_notes = citation(_, "clinical_notes")
      c_sessions = citation(_, "session_transcripts")
      html_notes = render_component(&CoreComponents.citation_list/1, citations: [c_notes])
      html_sessions = render_component(&CoreComponents.citation_list/1, citations: [c_sessions])

      for html <- [html_notes, html_sessions] do
        assert html =~ "<details"
        assert html =~ "<summary"
      end

      assert html_notes =~ "clinical_notes"
      refute html_notes =~ "session_transcripts"

      assert html_sessions =~ "session_transcripts"
    end
  end
end
