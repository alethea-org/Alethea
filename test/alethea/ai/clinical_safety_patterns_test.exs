defmodule Alethea.AI.ClinicalSafetyPatternsTest do
  @moduledoc """
  #316 AD1: `Alethea.AI.ClinicalSafetyPatterns` — the neutral, dependency-free
  catalog extracted from `HypothesisPolicy`. Regression proof: both regex
  lists keep their exact order and count, `normalize/1` keeps its folding
  behavior, and `HypothesisPolicy` delegates to this module verbatim
  (delegation parity).
  """
  use ExUnit.Case, async: true

  alias Alethea.AI.ClinicalSafetyPatterns
  alias Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy

  # `Regex.t()` cannot be compared with `==` across independent
  # evaluations: its `re_pattern` field is an opaque compiled term with
  # no structural equality guarantee (confirmed: even calling the same
  # accessor twice yields two `==`-unequal results despite identical
  # `source`/`opts`). Parity is therefore asserted on `{source, opts}`
  # pairs, which fully determine a regex's matching behavior.
  defp source_opts_pairs(regexes), do: Enum.map(regexes, &{&1.source, &1.opts})

  describe "diagnostic_patterns/0" do
    test "returns the 9 documented regexes in order" do
      patterns = ClinicalSafetyPatterns.diagnostic_patterns()

      assert length(patterns) == 9
      assert Enum.all?(patterns, &match?(%Regex{}, &1))
    end

    test "delegation parity: HypothesisPolicy.diagnostic_patterns/0 matches verbatim" do
      assert source_opts_pairs(HypothesisPolicy.diagnostic_patterns()) ==
               source_opts_pairs(ClinicalSafetyPatterns.diagnostic_patterns())
    end
  end

  describe "prescriptive_patterns/0" do
    test "returns the 9 documented regexes in order" do
      patterns = ClinicalSafetyPatterns.prescriptive_patterns()

      assert length(patterns) == 9
      assert Enum.all?(patterns, &match?(%Regex{}, &1))
    end

    test "delegation parity: HypothesisPolicy.prescriptive_patterns/0 matches verbatim" do
      assert source_opts_pairs(HypothesisPolicy.prescriptive_patterns()) ==
               source_opts_pairs(ClinicalSafetyPatterns.prescriptive_patterns())
    end
  end

  describe "normalize/1" do
    test "downcases text" do
      assert ClinicalSafetyPatterns.normalize("DIAGNÓSTICO") == "diagnostico"
    end

    test "folds accented vowels á é í ó ú ü to their plain form" do
      assert ClinicalSafetyPatterns.normalize("áéíóú ü") == "aeiou u"
    end

    test "keeps ñ unfolded" do
      assert ClinicalSafetyPatterns.normalize("Año") == "año"
    end

    test "collapses repeated whitespace and trims" do
      assert ClinicalSafetyPatterns.normalize("  hola   mundo  ") == "hola mundo"
    end
  end
end
