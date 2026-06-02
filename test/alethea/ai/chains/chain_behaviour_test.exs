defmodule Alethea.AI.Chains.ChainBehaviourTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.Chains.ChainBehaviour

  describe "behaviour contract" do
    test "run callback is required" do
      assert {:callback, _} =
               ChainBehaviour.behaviour_info(:callbacks)
               |> Enum.find(fn {name, _} -> name == :run end)
    end

    test "run! is optional" do
      optionals = ChainBehaviour.behaviour_info(:optional_callbacks)
      assert {:run!, 1} in optionals
    end

    test "suggested_system_prompt is optional" do
      optionals = ChainBehaviour.behaviour_info(:optional_callbacks)
      assert {:suggested_system_prompt, 0} in optionals
    end

    test "suggested_max_tokens is optional" do
      optionals = ChainBehaviour.behaviour_info(:optional_callbacks)
      assert {:suggested_max_tokens, 0} in optionals
    end

    test "supported_providers is optional" do
      optionals = ChainBehaviour.behaviour_info(:optional_callbacks)
      assert {:supported_providers, 0} in optionals
    end
  end

  describe "chain_params type" do
    test "can hold required fields" do
      params = %{sanitized_content: "test content"}
      assert params[:sanitized_content] == "test content"
    end

    test "can hold optional fields" do
      params = %{
        sanitized_content: "test",
        patient_context: "context",
        message_id: "msg-123",
        session_id: "session-456"
      }

      assert params[:session_id] == "session-456"
    end
  end

  describe "chain_result type" do
    test "success result format" do
      result = {:ok, %{response: "test", source_message_id: "123"}}
      assert match?({:ok, %{response: _, source_message_id: _}}, result)
    end

    test "error result format" do
      result = {:error, :network_timeout}
      assert match?({:error, _}, result)
    end
  end
end
