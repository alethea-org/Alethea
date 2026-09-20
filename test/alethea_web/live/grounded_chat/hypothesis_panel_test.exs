defmodule AletheaWeb.GroundedChat.HypothesisPanelTest do
  @moduledoc """
  Cubre los criterios de aceptación de la issue #231 (ADR-010): el
  panel *Hipótesis para revisar* debe estar visiblemente separado,
  llevar el disclaimer clínico server-owned antes de la afirmación,
  citar la evidencia con el renderer server-derived de #230 (sin
  markup propio) y desaparecer por completo cuando no hay hipótesis
  para el turno.

  Fixtures construidas vía `HypothesisPolicy.evaluate/2` (el único
  constructor real de `Hypothesis.t()`, #229) — mismo patrón que usa
  `hypothesis_policy_test.exs`, no structs armados a mano.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy
  alias AletheaWeb.GroundedChat.HypothesisPanel

  @statement "La reducción a corto plazo de la exposición podría estar funcionando como escape."

  @fixture_result_a %{
    chunk_id: "11111111-1111-1111-1111-111111111111",
    source_resource_type: "clinical_notes",
    source_resource_id: "22222222-2222-2222-2222-222222222222",
    source_occurred_at: ~U[2026-06-12 09:00:00Z],
    target_behavior_id: nil,
    content: "solicitó salir del aula antes de presentar"
  }

  @fixture_result_b %{
    chunk_id: "33333333-3333-3333-3333-333333333333",
    source_resource_type: "clinical_notes",
    source_resource_id: "44444444-4444-4444-4444-444444444444",
    source_occurred_at: ~U[2026-06-19 09:00:00Z],
    target_behavior_id: nil,
    content: "permaneció en el grupo pese a la aprensión"
  }

  @hypothesis (case HypothesisPolicy.evaluate(@statement, [@fixture_result_a]) do
                 {:ok, hypothesis} -> hypothesis
               end)

  @hypothesis_multi (case HypothesisPolicy.evaluate(@statement, [
                            @fixture_result_a,
                            @fixture_result_b
                          ]) do
                       {:ok, hypothesis} -> hypothesis
                     end)

  describe "hypothesis_panel/1" do
    test "no renderiza nada cuando no hay hipótesis para este turno" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          hypothesis: nil
        )

      assert String.trim(html) == ""
    end

    test "renderiza el panel con el disclaimer server-owned antes de la afirmación" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          hypothesis: @hypothesis
        )

      assert html =~ ~s(id="chat-turn-1-hypothesis")
      assert html =~ "Hipótesis para revisar"
      assert html =~ "Disclaimer clínico"
      assert html =~ @hypothesis.disclaimer

      {disclaimer_pos, _} = :binary.match(html, "Disclaimer clínico")
      {statement_pos, _} = :binary.match(html, @hypothesis.statement)

      assert disclaimer_pos < statement_pos
    end

    test "la evidencia se renderiza con el citation renderer real de #230, sin markup propio" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          hypothesis: @hypothesis
        )

      # DOM exacto de AletheaWeb.CoreComponents.citation/1 — mismo shape que Síntesis.
      assert html =~ "<details"
      assert html =~ "citation__summary"

      [source] = @hypothesis.sources
      short_chunk_id = source.reference.chunk_id |> String.slice(0, 8)
      expected_ref = "#{source.reference.resource_type}/#{short_chunk_id}"

      assert html =~ ~s(id="citation-#{expected_ref}")
      assert html =~ source.kind
    end

    test "con dos o más fuentes, cada una se cita de forma independiente" do
      html =
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          hypothesis: @hypothesis_multi
        )

      [source_a, source_b] = @hypothesis_multi.sources

      ref_a =
        "#{source_a.reference.resource_type}/#{String.slice(source_a.reference.chunk_id, 0, 8)}"

      ref_b =
        "#{source_b.reference.resource_type}/#{String.slice(source_b.reference.chunk_id, 0, 8)}"

      assert html =~ ~s(id="citation-#{ref_a}")
      assert html =~ ~s(id="citation-#{ref_b}")

      lazy = LazyHTML.from_fragment(html)
      assert lazy |> LazyHTML.query("details") |> Enum.count() == 2
    end

    test "rechaza una fuente con excerpt vacío — HypothesisPolicy no lo garantiza por elemento" do
      empty_excerpt_result = Map.put(@fixture_result_a, :content, "")

      {:ok, hypothesis_with_empty_source} =
        HypothesisPolicy.evaluate(@statement, [empty_excerpt_result])

      assert_raise ArgumentError, fn ->
        render_component(&HypothesisPanel.hypothesis_panel/1,
          id: "chat-turn-1-hypothesis",
          hypothesis: hypothesis_with_empty_source
        )
      end
    end
  end
end
