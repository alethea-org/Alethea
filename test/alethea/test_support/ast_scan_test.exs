defmodule AletheaTest.ASTScanTest do
  @moduledoc """
  #235a0: unit coverage for the shared AST walker extracted from
  `hypothesis_policy_test.exs`'s Sole Constructor Gate (PR #273), per
  design `grounded-chat-235-integration` AD5's positive/negative
  table. Parses source snippets directly (never compiles them) so no
  referenced module needs to actually exist.
  """
  use ExUnit.Case, async: true

  alias AletheaTest.ASTScan

  defp ast(source), do: Code.string_to_quoted!(source)

  describe "calls?/3 — call-site detection (positive forms)" do
    test "qualified call: HypothesisPolicy.evaluate(a, b)" do
      assert ASTScan.calls?(ast("HypothesisPolicy.evaluate(a, b)"), :HypothesisPolicy, [
               :evaluate
             ])
    end

    test "aliased-segment call matches by suffix, not equality" do
      source = "Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy.evaluate(a, b)"
      assert ASTScan.calls?(ast(source), :HypothesisPolicy, [:evaluate])
    end

    test "capture: &HypothesisPolicy.evaluate/2" do
      assert ASTScan.calls?(ast("&HypothesisPolicy.evaluate/2"), :HypothesisPolicy, [:evaluate])
    end

    test "apply/3: apply(HypothesisPolicy, :evaluate, args)" do
      source = "apply(HypothesisPolicy, :evaluate, args)"
      assert ASTScan.calls?(ast(source), :HypothesisPolicy, [:evaluate])
    end

    test "import ...HypothesisPolicy opens the unqualified-call bypass" do
      source = "import Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy"
      assert ASTScan.calls?(ast(source), :HypothesisPolicy, [:evaluate])
    end
  end

  describe "calls?/3 — non-call forms (negative controls)" do
    test "a moduledoc string merely mentioning the call is not a call" do
      source = ~s(@moduledoc "See HypothesisPolicy.evaluate/2 for context.")
      refute ASTScan.calls?(ast(source), :HypothesisPolicy, [:evaluate])
    end

    test "an alias declaration is not a call" do
      source = "alias Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy"
      refute ASTScan.calls?(ast(source), :HypothesisPolicy, [:evaluate])
    end

    test "a %Struct{} pattern-match in a function head is not a call" do
      source = "def f(%Hypothesis{} = h), do: h"
      refute ASTScan.calls?(ast(source), :HypothesisPolicy, [:evaluate])
    end
  end

  describe "constructs_struct?/2 — expression vs pattern context" do
    test "construction in expression position counts" do
      source = """
      def f do
        %Hypothesis{statement: "x"}
      end
      """

      assert ASTScan.constructs_struct?(ast(source), :Hypothesis)
    end

    test "a %Struct{} pattern-match in a function head does not count as construction" do
      source = "def f(%Hypothesis{} = h), do: h"
      refute ASTScan.constructs_struct?(ast(source), :Hypothesis)
    end

    test "construction of an unrelated struct is not flagged, but its contents are still walked" do
      source = """
      def f do
        %Other{nested: %Hypothesis{statement: "y"}}
      end
      """

      assert ASTScan.constructs_struct?(ast(source), :Hypothesis)
      refute ASTScan.constructs_struct?(ast(source), :Missing)
    end
  end

  describe "lib_files/1" do
    test "excludes paths ending with a given suffix" do
      files = ASTScan.lib_files(exclude: ["hypothesis_policy.ex"])
      refute Enum.any?(files, &String.ends_with?(&1, "hypothesis_policy.ex"))
      assert Enum.any?(files, &String.ends_with?(&1, ".ex"))
    end
  end

  describe "parse!/1" do
    test "reads and parses a real lib file into a valid AST" do
      [file | _] = ASTScan.lib_files(exclude: [])
      assert {_, _, _} = ASTScan.parse!(file)
    end
  end
end
