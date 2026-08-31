defmodule Alethea.AI.Chains.PatternProposalChainTest do
  @moduledoc """
  RED-phase specs for `Alethea.AI.Chains.PatternProposalChain`
  (sdd/alethea/issue-195-clinical-review-workbench, GitHub #195, PR4,
  task 6.1). Exercises only the chain's pure functions
  (`build_prompt/1`, `parse_proposals/1`) plus `LLMConfig` config
  resolution — no live LLM endpoint is invoked, matching the existing
  convention for `SessionSummaryChain`/`WeeklySummaryChain` (neither has
  a direct network-invoking test; their `run/1` orchestration is
  exercised indirectly through their respective workers via Mox).
  """
  use ExUnit.Case, async: true

  alias Alethea.AI.Chains.PatternProposalChain
  alias Alethea.AI.LLMConfig

  describe "build_prompt/1" do
    test "joins sanitized evidence strings with a separator" do
      prompt = PatternProposalChain.build_prompt(["Primera evidencia", "Segunda evidencia"])

      assert prompt =~ "Primera evidencia"
      assert prompt =~ "Segunda evidencia"
      assert prompt =~ "---"
    end

    test "returns a non-empty prompt for a single evidence item" do
      prompt = PatternProposalChain.build_prompt(["Unica evidencia"])

      assert prompt =~ "Unica evidencia"
      refute prompt =~ "---"
    end
  end

  describe "parse_proposals/1" do
    test "extracts the proposals list from a well-formed JSON response" do
      raw = ~s({"proposals": ["Patron A", "Patron B"]})

      assert PatternProposalChain.parse_proposals(raw) == ["Patron A", "Patron B"]
    end

    test "drops non-string entries from the proposals list" do
      raw = ~s({"proposals": ["Patron valido", 42, null]})

      assert PatternProposalChain.parse_proposals(raw) == ["Patron valido"]
    end

    test "returns an empty list for malformed JSON" do
      assert PatternProposalChain.parse_proposals("no es json") == []
    end

    test "returns an empty list when the proposals key is missing" do
      assert PatternProposalChain.parse_proposals(~s({"other" => "value"})) == []
    end
  end

  describe "suggested_system_prompt/0" do
    test "never instructs the model to diagnose, recommend, or write a note" do
      prompt = PatternProposalChain.suggested_system_prompt()

      assert prompt =~ "NUNCA diagnostiques"
      assert prompt =~ "NUNCA recomiendes"
      assert prompt =~ "NUNCA redactes una nota clínica"
      assert prompt =~ "HIPÓTESIS PROVISIONAL"
    end
  end

  describe "LLMConfig integration" do
    test "resolves a :pattern_proposal chain config and builds a local adapter" do
      assert {:ok, config, %Alethea.AI.ChatModels.OllamaChat{} = model} =
               LLMConfig.get_and_build(:pattern_proposal)

      assert model.model == config.model
      assert config.provider == :local
    end
  end
end
