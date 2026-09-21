defmodule Alethea.ClinicalRecord.Rag.Consultation.HypothesisWiringGateTest do
  @moduledoc """
  Hypothesis Wiring Gate (#235, design AD5): enforces PD3/R9/R11 —
  `HypothesisPolicy.interpretive_intent?/1` and `HypothesisPolicy.evaluate/2`
  are called from exactly one place, `Consultation.Live`'s `maybe_hypothesis/3`.
  Spans domain and web, so it lives in neither `live_test.exs` (a `DataCase`)
  nor `consultation_live_test.exs` (a `ConnCase`) — a standalone, DB-free
  static scan, mirroring `hypothesis_policy_test.exs`'s Sole Constructor Gate.

  AST-aware via `AletheaTest.ASTScan.calls?/3`, never textual/`grep`-style: a
  `@moduledoc`/comment merely mentioning `HypothesisPolicy` in prose must
  never be mistaken for a real call — the false-positive class PR #273 fixed.
  """
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.Rag.Consultation.Answer
  alias AletheaTest.ASTScan

  @allowed_call_site "consultation/live.ex"

  describe "Hypothesis Wiring Gate — AST scan" do
    test "no lib file outside consultation/live.ex calls interpretive_intent?/1 or evaluate/2" do
      violations =
        ASTScan.lib_files(exclude: [@allowed_call_site])
        |> Enum.filter(fn path ->
          path
          |> ASTScan.parse!()
          |> ASTScan.calls?(:HypothesisPolicy, [:interpretive_intent?, :evaluate])
        end)

      assert violations == []
    end

    test "consultation/live.ex itself does call the policy (sanity — the gate isn't vacuous)" do
      call_site =
        ASTScan.lib_files()
        |> Enum.find(&String.ends_with?(&1, @allowed_call_site))

      assert call_site

      assert call_site
             |> ASTScan.parse!()
             |> ASTScan.calls?(:HypothesisPolicy, [:interpretive_intent?, :evaluate])
    end

    test "negative control: a moduledoc merely mentioning HypothesisPolicy.evaluate/2 in prose is not a violation" do
      source = """
      defmodule Sample do
        @moduledoc \"\"\"
        This module does not call HypothesisPolicy.evaluate/2 or
        HypothesisPolicy.interpretive_intent?/1 — it only mentions them in prose,
        the same false-positive class PR #273 fixed.
        \"\"\"

        def noop, do: :ok
      end
      """

      refute source
             |> Code.string_to_quoted!()
             |> ASTScan.calls?(:HypothesisPolicy, [:interpretive_intent?, :evaluate])
    end
  end

  describe "Answer.outcome/0 vocabulary is unchanged (#235, R11)" do
    test "remains exactly :synthesis | :no_evidence | :stale | :provider_failure" do
      {:ok, types} = Code.Typespec.fetch_types(Answer)

      {:type, {:outcome, union, []}} =
        Enum.find(types, fn {:type, {name, _, _}} -> name == :outcome end)

      assert flatten_union(union) == [:synthesis, :no_evidence, :stale, :provider_failure]
    end
  end

  defp flatten_union({:type, _, :union, members}), do: Enum.flat_map(members, &flatten_union/1)
  defp flatten_union({:atom, _, value}), do: [value]
end
