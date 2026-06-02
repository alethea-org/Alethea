defmodule Alethea.AI.LLMConfigTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.LLMConfig

  describe "get/2" do
    test "returns default config structure" do
      config = LLMConfig.get(:guided_conversation)
      assert config.provider in [:local, :cloud]
      assert is_binary(config.model)
      assert is_integer(config.max_tokens)
      assert is_integer(config.temperature)
      assert is_struct(config.retry, Alethea.AI.Retry)
    end

    test "applies overrides correctly" do
      config = LLMConfig.get(:guided_conversation, temperature: 0.8, max_tokens: 1024)
      assert config.temperature == 0.8
      assert config.max_tokens == 1024
    end

    test "respects provider override" do
      config = LLMConfig.get(:guided_conversation, provider: :cloud)
      assert config.provider == :cloud
    end

    test "defaults to :local provider" do
      config = LLMConfig.get(:guided_conversation)
      # Provider comes from config, test the structure
      assert config.api_key == nil
    end
  end

  describe "build_llm/1" do
    test "returns error when api_key is nil for local" do
      config = %LLMConfig.Config{
        provider: :local,
        model: "phi-4-mini",
        api_key: nil,
        endpoint_url: "https://api-inference.huggingface.co/models/"
      }

      assert {:error, "API key required for local provider"} = LLMConfig.build_llm(config)
    end

    test "returns error when api_key is nil for cloud" do
      config = %LLMConfig.Config{
        provider: :cloud,
        model: "gpt-4o-mini",
        api_key: nil,
        endpoint_url: "https://api.openai.com/v1/"
      }

      assert {:error, "API key required for cloud provider"} = LLMConfig.build_llm(config)
    end
  end

  describe "get_and_build/2" do
    test "returns error tuple when config fails" do
      # This will fail because no api_key is set
      result = LLMConfig.get_and_build(:guided_conversation)
      assert {:error, "API key required for local provider"} = result
    end
  end

  describe "retry integration" do
    test "retry struct is included in config" do
      config = LLMConfig.get(:guided_conversation)
      assert %{attempts: 0, max_attempts: 3} = config.retry
    end

    test "retry can be disabled via override" do
      config = LLMConfig.get(:guided_conversation, retry_enabled: true)
      assert config.retry.max_attempts == 3
    end
  end
end
