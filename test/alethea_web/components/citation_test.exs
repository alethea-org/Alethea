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

  import Phoenix.Component
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
    test "renders kind, ref and fecha as the summary — excerpt is present but visually collapsed (native <details>, no `open` attribute)" do
      html = render_component(&CoreComponents.citation/1, citation: citation())

      assert html =~ "<details"
      refute html =~ "open"

      assert html =~ "clinical_notes"
      assert html =~ Citation.ref(@valid_result)

      assert html =~ "2026-08-12"

      # The excerpt is always in the DOM — native <details> hides it
      # visually until opened, so a real click works with zero JS.
      # Structurally omitting it here (the pre-fix behavior) made
      # click-to-expand unreachable, since no production call site
      # ever re-renders with `expanded: true` (#235c task 3.0).
      assert html =~ "El paciente reportó insomnio"
    end

    test "uses a stable DOM id derived from the source_ref" do
      c = citation()
      html = render_component(&CoreComponents.citation/1, citation: c)

      assert html =~ "id=\"citation-#{c.source_ref}\""
    end

    test "renders a plain <summary> with no stale ARIA state" do
      html = render_component(&CoreComponents.citation/1, citation: citation())

      assert html =~ "<summary"

      # #235c/Judgment Day: native <details>/<summary> already exposes
      # open/closed to assistive tech; a server-rendered aria-expanded
      # would go stale the moment a real click toggles it (unreachable
      # before the excerpt-gating fix — see task 3.0 — and now a real
      # regression to guard against).
      refute html =~ "aria-expanded"
      refute html =~ "aria-controls"
    end
  end

  describe "<.citation> kind label" do
    test "humanizes patient_message as the patient's voice (#262 label carried into citation/1)" do
      c = %Citation{
        source_ref: "patient_message/abcd1234",
        kind: "patient_message",
        occurred_at: ~U[2026-02-03 18:30:00Z],
        excerpt: "Me costó dormir esta semana.",
        score: nil,
        chunk_index: nil
      }

      html = render_component(&CoreComponents.citation/1, citation: c)

      assert html =~ "Mensaje del paciente"
      refute html =~ ">patient_message<"
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

  describe "citation/1 — optional link slot" do
    test "renders the :link slot's content inside <summary> when the caller passes it" do
      assigns = %{citation: citation()}

      html =
        rendered_to_string(~H"""
        <CoreComponents.citation citation={@citation}>
          <:link>Ver conducta objetivo</:link>
        </CoreComponents.citation>
        """)

      assert html =~ "Ver conducta objetivo"

      summary_start = :binary.match(html, "<summary") |> elem(0)
      summary_end = :binary.match(html, "</summary>") |> elem(0)
      link_pos = :binary.match(html, "Ver conducta objetivo") |> elem(0)

      assert summary_start < link_pos and link_pos < summary_end
    end

    test "no link and no error when the caller passes no :link slot" do
      assigns = %{citation: citation()}

      html =
        rendered_to_string(~H"""
        <CoreComponents.citation citation={@citation} />
        """)

      refute html =~ "citation__link"
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
      c_notes = citation(%{}, "clinical_notes")
      c_sessions = citation(%{}, "session_transcripts")
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
