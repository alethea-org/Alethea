defmodule AletheaWeb.GroundedChat.HypothesisPanelTest do
  @moduledoc """
  Cubre los criterios de aceptación de la issue #231 (ADR-010): el
  panel *Hipótesis para revisar* debe estar visiblemente separado,
  llevar disclaimer clínico antes del contenido interpretativo, citar
  cada afirmación con el renderer server-derived de #230 (sin markup
  propio) y desaparecer por completo cuando la consulta no es
  interpretativa.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Alethea.ClinicalRecord.Rag.Citation
  alias AletheaWeb.GroundedChat.HypothesisPanel
  alias AletheaWeb.GroundedChat.HypothesisPanel.Claim

  @retrieval_result %{
    chunk_id: "11111111-1111-1111-1111-111111111111",
    source_resource_type: "clinical_notes",
    source_resource_id: "22222222-2222-2222-2222-222222222222",
    source_occurred_at: ~U[2026-06-12 09:00:00Z],
    target_behavior_id: nil,
    chunk_index: 0,
    full_event: true,
    content: "solicitó salir del aula antes de presentar",
    dense_distance: 0.1,
    lexical_score: 0.7,
    score: 0.83
  }

  @citation Citation.from_retrieval_result(@retrieval_result)

  @claim Claim.build(
           "hyp-claim-1",
           "La reducción a corto plazo de la exposición podría estar funcionando como escape.",
           [@citation]
         )

  # Difiere en :chunk_index de @retrieval_result — Citation.ref/1 es
  # determinístico, así que dos citas con el mismo id/chunk producirían
  # el mismo `source_ref` y, por lo tanto, el mismo id de DOM (ver D4,
  # design.md §5).
  @retrieval_result_b Map.put(@retrieval_result, :chunk_index, 1)
  @citation_b Citation.from_retrieval_result(@retrieval_result_b)

  @claim_a Claim.build(
             "hyp-claim-1",
             "La reducción a corto plazo de la exposición podría estar funcionando como escape.",
             [@citation]
           )
  @claim_b Claim.build(
             "hyp-claim-2",
             "El comportamiento evitativo se refuerza tras cada episodio de escape.",
             [@citation_b]
           )

  describe "@moduledoc disclosures" do
    test "declara Claim.t()/interpretive? como interfaz provisional pendiente de #229 (PD1) y el disclaimer como borrador pendiente de sign-off clínico/legal (PD4)" do
      moduledoc = moduledoc_text(HypothesisPanel)

      assert moduledoc =~ "provisional"
      assert moduledoc =~ "#229"
      assert moduledoc =~ "borrador"
      assert moduledoc =~ "clínic"
    end
  end

  describe "Claim.build/3" do
    test "construye un %Claim{} válido" do
      assert %Claim{id: "hyp-claim-x", statement: "afirmación válida", citations: [@citation]} =
               Claim.build("hyp-claim-x", "afirmación válida", [@citation])
    end

    test "rechaza id no-binario" do
      assert_raise ArgumentError, fn -> Claim.build(123, "afirmación", [@citation]) end
    end

    test "rechaza id vacío" do
      assert_raise ArgumentError, fn -> Claim.build("", "afirmación", [@citation]) end
    end

    test "rechaza statement vacío" do
      assert_raise ArgumentError, fn -> Claim.build("hyp-claim-x", "", [@citation]) end
    end

    test "rechaza citations con un elemento que no es %Citation{}" do
      assert_raise ArgumentError, fn ->
        Claim.build("hyp-claim-x", "afirmación", [@citation, %{not: "a citation"}])
      end
    end
  end

  describe "hypothesis_panel/1" do
    test "no renderiza nada cuando la consulta no es interpretativa" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          interpretive?: false,
          claims: [@claim]
        )

      assert String.trim(html) == ""
    end

    test "renderiza el panel separado con el disclaimer antes de la primera afirmación" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          interpretive?: true,
          claims: [@claim]
        )

      assert html =~ ~s(id="chat-turn-1-hypothesis")
      assert html =~ "Hipótesis para revisar"
      assert html =~ "Disclaimer clínico"
      assert html =~ "No es un diagnóstico ni una recomendación terapéutica"

      {disclaimer_pos, _} = :binary.match(html, "Disclaimer clínico")
      {claim_pos, _} = :binary.match(html, @claim.statement)

      assert disclaimer_pos < claim_pos
    end

    test "cada afirmación se renderiza con el citation renderer real de #230, sin markup propio" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          interpretive?: true,
          claims: [@claim]
        )

      assert html =~ ~s(id="hyp-claim-1")
      assert html =~ @claim.statement

      # DOM exacto de AletheeWeb.CoreComponents.citation/1 — mismo shape que Síntesis.
      assert html =~ "<details"
      assert html =~ ~s(id="citation-#{@citation.source_ref}")
      assert html =~ "citation__summary"
      assert html =~ @citation.kind
    end

    test "puede renderizar el panel sin afirmaciones todavía (C1 autorizó pero no hay claims)" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          interpretive?: true,
          claims: []
        )

      assert html =~ "Hipótesis para revisar"
      refute html =~ "<details"
    end

    test "con dos o más afirmaciones, preserva el orden de la lista y no mezcla las citas entre afirmaciones" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          interpretive?: true,
          claims: [@claim_a, @claim_b]
        )

      {statement_a_pos, _} = :binary.match(html, @claim_a.statement)
      {statement_b_pos, _} = :binary.match(html, @claim_b.statement)
      {disclaimer_pos, _} = :binary.match(html, "Disclaimer clínico")

      assert statement_a_pos < statement_b_pos
      assert disclaimer_pos < statement_a_pos
      assert disclaimer_pos < statement_b_pos

      assert html =~ ~s(id="hyp-claim-1")
      assert html =~ ~s(id="hyp-claim-2")

      lazy = LazyHTML.from_fragment(html)

      claim_a_citation_ids =
        lazy |> LazyHTML.query("li#hyp-claim-1 details") |> LazyHTML.attribute("id")

      claim_b_citation_ids =
        lazy |> LazyHTML.query("li#hyp-claim-2 details") |> LazyHTML.attribute("id")

      assert claim_a_citation_ids == ["citation-#{@citation.source_ref}"]
      assert claim_b_citation_ids == ["citation-#{@citation_b.source_ref}"]

      assert lazy |> LazyHTML.query("details") |> Enum.count() == 2
      assert lazy |> LazyHTML.query("section.citation-list") |> Enum.count() == 2
    end
  end

  defp moduledoc_text(module) do
    {:docs_v1, _annotation, _language, _format, module_doc, _metadata, _docs} =
      Code.fetch_docs(module)

    case module_doc do
      %{} = docs -> docs |> Map.values() |> Enum.join("\n")
      _ -> ""
    end
  end
end
