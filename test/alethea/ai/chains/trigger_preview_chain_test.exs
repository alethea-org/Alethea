defmodule Alethea.AI.Chains.TriggerPreviewChainTest do
  @moduledoc """
  Specs for `Alethea.AI.Chains.TriggerPreviewChain` (issue #440).
  """
  use ExUnit.Case, async: true

  alias Alethea.AI.Chains.TriggerPreviewChain
  alias Alethea.AI.LLMConfig

  describe "chain properties" do
    test "implements ChainBehaviour" do
      Code.ensure_loaded!(TriggerPreviewChain)
      assert function_exported?(TriggerPreviewChain, :run, 1)
      assert function_exported?(TriggerPreviewChain, :run!, 1)
      assert function_exported?(TriggerPreviewChain, :suggested_system_prompt, 0)
      assert function_exported?(TriggerPreviewChain, :suggested_max_tokens, 0)
      assert function_exported?(TriggerPreviewChain, :supported_providers, 0)
    end

    test "system prompt is in Spanish, clinically neutral and instructs bot voice" do
      prompt = TriggerPreviewChain.suggested_system_prompt()
      assert prompt =~ "Alethea"
      assert prompt =~ "clínicamente neutral"
      assert prompt =~ "español"
    end

    test "build_prompt sanitizes sensitive information at the boundary" do
      raw_instruction = "Recordar llamar al +56 9 1234 5678 o escribir a test@example.com"
      prompt = TriggerPreviewChain.build_prompt(raw_instruction)

      refute prompt =~ "+56 9 1234 5678"
      refute prompt =~ "test@example.com"
      assert prompt =~ "[REDACTED_PHONE]"
      assert prompt =~ "[REDACTED_EMAIL]"
    end

    test "resolves configuration through LLMConfig for :trigger_preview" do
      assert %LLMConfig.Config{} = LLMConfig.get(:trigger_preview)
    end
  end
end
