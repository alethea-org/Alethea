defmodule Alethea.AI.LLMConfigTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.LLMConfig
  alias Alethea.AI.Chains.GuidedConversationChain

  setup do
    originals =
      Map.new(
        [GuidedConversationChain, LLMConfig, :env],
        &{&1, Application.fetch_env(:alethea, &1)}
      )

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:alethea, key, value)
        {key, :error} -> Application.delete_env(:alethea, key)
      end)
    end)

    :ok
  end

  describe "get/2" do
    test "returns default config structure" do
      config = LLMConfig.get(:guided_conversation)
      assert config.provider in [:local, :cloud]
      assert is_binary(config.model)
      assert is_integer(config.max_tokens)
      assert is_number(config.temperature)
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

    test "consumes the guided conversation module configuration" do
      Application.put_env(:alethea, GuidedConversationChain,
        provider: :local,
        model: "phi4-mini:demo",
        local: [endpoint_url: "http://ollama.test:11434"]
      )

      config = LLMConfig.get(:guided_conversation)

      assert config.model == "phi4-mini:demo"
      assert config.endpoint_url == "http://ollama.test:11434"
    end

    test "the global endpoint applies to chains without their own" do
      Application.put_env(:alethea, LLMConfig,
        local: [endpoint_url: "http://llm.internal.test:11434"]
      )

      for chain <- [:session_summary, :weekly_summary, :pattern_proposal, :consultation_synthesis] do
        config = LLMConfig.get(chain)

        assert config.provider == :local
        assert config.endpoint_url == "http://llm.internal.test:11434"
      end
    end

    test "development keeps the local Ollama default endpoint" do
      Application.delete_env(:alethea, LLMConfig)

      assert LLMConfig.get(:session_summary).endpoint_url == "http://localhost:11434"
    end

    test "production has no default local endpoint" do
      Application.put_env(:alethea, :env, :prod)
      Application.put_env(:alethea, LLMConfig, local: [], cloud: [api_key: "synthetic-api-key"])

      # `:consultation_synthesis` is pinned to `:local`; without a local
      # endpoint it must resolve to "not configured", never to localhost
      # and never to the hosted provider.
      config = LLMConfig.get(:consultation_synthesis)

      assert config.provider == :local
      assert config.endpoint_url == nil

      assert {:error, reason} = LLMConfig.get_and_build(:consultation_synthesis)
      assert reason =~ "not configured"
      refute reason =~ "synthetic-api-key"
    end

    test "a blank API key resolves to no key" do
      Application.put_env(:alethea, GuidedConversationChain, provider: :cloud, api_key: "  ")

      assert LLMConfig.get(:guided_conversation, provider: :cloud).api_key == nil
    end

    test "defaults to :local provider" do
      config = LLMConfig.get(:guided_conversation)
      assert config.provider == :local
    end
  end

  describe "build_llm/1" do
    test "builds the credential-free Ollama adapter for local" do
      config = %LLMConfig.Config{
        provider: :local,
        model: "phi4-mini",
        api_key: nil,
        endpoint_url: "http://localhost:11434"
      }

      assert {:ok, %Alethea.AI.ChatModels.OllamaChat{} = model} = LLMConfig.build_llm(config)
      assert model.model == "phi4-mini"
      assert model.endpoint_url == "http://localhost:11434"
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

  describe "build_llm/1 — misconfiguration" do
    test "returns error when api_key is empty for cloud" do
      for api_key <- ["", "   "] do
        config = %LLMConfig.Config{
          provider: :cloud,
          model: "gpt-4o-mini",
          api_key: api_key,
          endpoint_url: "https://api.openai.com/v1/"
        }

        assert {:error, "API key required for cloud provider"} = LLMConfig.build_llm(config)
      end
    end

    test "returns error when the endpoint is not configured" do
      config = %LLMConfig.Config{
        provider: :local,
        model: "phi4-mini",
        api_key: nil,
        endpoint_url: nil
      }

      assert {:error, "LLM endpoint for the :local provider is not configured"} =
               LLMConfig.build_llm(config)
    end
  end

  describe "get_and_build/2" do
    test "returns the resolved config and local adapter" do
      assert {:ok, config, %Alethea.AI.ChatModels.OllamaChat{} = model} =
               LLMConfig.get_and_build(:guided_conversation)

      assert model.model == config.model
      assert model.endpoint_url == config.endpoint_url
    end
  end

  describe "retry integration" do
    test "retry struct is included in config" do
      config = LLMConfig.get(:guided_conversation)
      assert config.retry.max_attempts == 1
    end

    test "retry can be disabled via override" do
      config = LLMConfig.get(:guided_conversation, retry_enabled: true)
      assert config.retry.max_attempts == 3
    end
  end
end
