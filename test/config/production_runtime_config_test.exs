defmodule Alethea.ProductionRuntimeConfigTest do
  @moduledoc """
  Evaluates `config/runtime.exs` as `:prod` (issue #402) and pins the
  production contract: verified database TLS, a required host with an
  explicit `check_origin`, no `localhost` AI endpoint, and AI capabilities
  that are either explicitly enabled with their endpoint or explicitly
  disabled. Every value below is synthetic.
  """

  use ExUnit.Case, async: false

  alias Alethea.AI.Chains.{ClinicalConsultationChain, GuidedConversationChain}
  alias Alethea.AI.{Embeddings, EmotionAnalyzer, LLMConfig, Whisper}

  @managed_env ~w(
    DATABASE_URL DATABASE_SSL POOL_SIZE ECTO_IPV6
    DATABASE_CONNECT_TIMEOUT_MS DATABASE_QUEUE_TARGET_MS DATABASE_QUEUE_INTERVAL_MS
    SECRET_KEY_BASE PHX_HOST PHX_EXTRA_ORIGINS PHX_SERVER PORT DNS_CLUSTER_QUERY
    CLOAK_AES_KEY TELEGRAM_CHAT_ID_PEPPER TELEGRAM_CLIENT_ADAPTER
    AI_PROVIDER LLM_MODEL LOCAL_LLM_BASE_URL OPENAI_API_KEY OPENAI_BASE_URL
    EMOTION_ANALYZER_ENABLED EMOTION_SIDECAR_URL
    EMBEDDINGS_ENABLED EMBEDDINGS_BASE_URL EMBEDDINGS_MODEL
    WHISPER_ENABLED
  )

  @complete_env %{
    "DATABASE_URL" => "ecto://synthetic:synthetic@db.example.test/alethea_prod",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "app.example.test",
    "CLOAK_AES_KEY" => "c3ludGhldGljLXN5bnRoZXRpYy1zeW50aGV0aWMtMzI=",
    "TELEGRAM_CHAT_ID_PEPPER" => "synthetic-test-pepper",
    "AI_PROVIDER" => "local",
    "LOCAL_LLM_BASE_URL" => "http://llm.internal.test:11434",
    "EMOTION_ANALYZER_ENABLED" => "false",
    "EMBEDDINGS_ENABLED" => "false"
  }

  describe "database" do
    test "verifies the server certificate by default" do
      repo = prod_config() |> alethea(Alethea.Repo)

      assert [cacerts: cacerts] = repo[:ssl]
      assert is_list(cacerts) and cacerts != []
      assert repo[:url] == @complete_env["DATABASE_URL"]
    end

    test "only the exact literal false disables TLS" do
      assert prod_config(%{"DATABASE_SSL" => "false"})
             |> alethea(Alethea.Repo)
             |> Keyword.get(:ssl) ==
               false

      for value <- ["False", "FALSE", "0", "no", "off", "", " false", "true"] do
        ssl =
          prod_config(%{"DATABASE_SSL" => value}) |> alethea(Alethea.Repo) |> Keyword.get(:ssl)

        assert [cacerts: _] = ssl, "DATABASE_SSL=#{inspect(value)} must keep TLS on"
      end
    end

    test "uses connection settings that tolerate a resuming compute" do
      repo = prod_config() |> alethea(Alethea.Repo)

      assert repo[:pool_size] == 5
      assert repo[:connect_timeout] == 15_000
      assert repo[:handshake_timeout] == 15_000
      assert repo[:queue_target] == 2_000
      assert repo[:queue_interval] == 10_000
      assert repo[:backoff_type] == :rand_exp
      assert repo[:backoff_max] == 10_000
      assert repo[:socket_options] == []
      refute Keyword.has_key?(repo, :prepare)
    end

    test "connection settings are tunable through the environment" do
      repo =
        prod_config(%{
          "POOL_SIZE" => "12",
          "DATABASE_CONNECT_TIMEOUT_MS" => "20000",
          "DATABASE_QUEUE_TARGET_MS" => "750",
          "DATABASE_QUEUE_INTERVAL_MS" => "5000",
          "ECTO_IPV6" => "true"
        })
        |> alethea(Alethea.Repo)

      assert repo[:pool_size] == 12
      assert repo[:connect_timeout] == 20_000
      assert repo[:handshake_timeout] == 20_000
      assert repo[:queue_target] == 750
      assert repo[:queue_interval] == 5_000
      assert repo[:socket_options] == [:inet6]
    end
  end

  describe "endpoint" do
    test "PHX_HOST is required" do
      assert_raise RuntimeError, ~r/PHX_HOST is missing or empty/, fn ->
        prod_config(%{"PHX_HOST" => nil})
      end

      assert_raise RuntimeError, ~r/PHX_HOST is missing or empty/, fn ->
        prod_config(%{"PHX_HOST" => "  "})
      end
    end

    test "PHX_HOST must be a bare host name" do
      assert_raise RuntimeError, ~r/PHX_HOST must be a bare host name/, fn ->
        prod_config(%{"PHX_HOST" => "https://app.example.test"})
      end
    end

    test "check_origin is derived from the host" do
      endpoint = prod_config() |> alethea(AletheaWeb.Endpoint)

      assert endpoint[:url] == [host: "app.example.test", port: 443, scheme: "https"]
      assert endpoint[:check_origin] == ["https://app.example.test"]
    end

    test "extra origins are appended from a comma-separated override" do
      endpoint =
        prod_config(%{
          "PHX_EXTRA_ORIGINS" => "https://alethea.example.test, https://www.example.test ,"
        })
        |> alethea(AletheaWeb.Endpoint)

      assert endpoint[:check_origin] == [
               "https://app.example.test",
               "https://alethea.example.test",
               "https://www.example.test"
             ]
    end
  end

  describe "LLM provider" do
    test "AI_PROVIDER must be set explicitly to a supported value" do
      assert_raise RuntimeError, ~r/AI_PROVIDER is missing/, fn ->
        prod_config(%{"AI_PROVIDER" => nil})
      end

      error =
        assert_raise RuntimeError, ~r/AI_PROVIDER has an unsupported value/, fn ->
          prod_config(%{"AI_PROVIDER" => "synthetic-unknown-provider"})
        end

      refute error.message =~ "synthetic-unknown-provider"
    end

    test "the local provider requires its endpoint" do
      assert_raise RuntimeError, ~r/LOCAL_LLM_BASE_URL is missing or empty/, fn ->
        prod_config(%{"LOCAL_LLM_BASE_URL" => nil})
      end
    end

    test "the local endpoint is the global endpoint for every chain" do
      config = prod_config()

      assert alethea(config, LLMConfig)[:local] == [
               endpoint_url: "http://llm.internal.test:11434"
             ]

      assert alethea(config, GuidedConversationChain)[:provider] == :local
    end

    test "the hosted provider rejects a missing or empty API key" do
      for key <- [nil, "", "   "] do
        assert_raise RuntimeError, ~r/OPENAI_API_KEY is missing or empty/, fn ->
          prod_config(cloud_env(%{"OPENAI_API_KEY" => key}))
        end
      end
    end

    test "the hosted provider requires an explicit model" do
      assert_raise RuntimeError, ~r/LLM_MODEL is missing or empty/, fn ->
        prod_config(cloud_env(%{"LLM_MODEL" => nil}))
      end
    end

    test "the hosted provider never falls back to a local endpoint" do
      config = prod_config(cloud_env())
      llm = alethea(config, LLMConfig)
      guided = alethea(config, GuidedConversationChain)

      assert guided[:provider] == :cloud
      assert guided[:model] == "synthetic-hosted-model"
      assert llm[:cloud][:api_key] == "synthetic-api-key"
      assert llm[:cloud][:endpoint_url] == "https://api.openai.com/v1"
      # No local endpoint is configured, so chains pinned to `:local`
      # resolve to "not configured" instead of a localhost default.
      assert llm[:local] == []
      refute Keyword.has_key?(llm, :provider)
    end

    test "boot errors never echo the secret values" do
      error =
        assert_raise RuntimeError, fn ->
          prod_config(cloud_env(%{"LLM_MODEL" => nil}))
        end

      refute error.message =~ "synthetic-api-key"
    end
  end

  describe "capability switches" do
    test "each switch must be set explicitly to true or false" do
      for name <- ["EMOTION_ANALYZER_ENABLED", "EMBEDDINGS_ENABLED"] do
        assert_raise RuntimeError, ~r/#{name} is missing/, fn ->
          prod_config(%{name => nil})
        end

        assert_raise RuntimeError, ~r/#{name} must be exactly true or false/, fn ->
          prod_config(%{name => "yes"})
        end
      end
    end

    test "emotion analyzer disabled" do
      config = prod_config()

      assert alethea(config, :emotion_analyzer) == EmotionAnalyzer.Disabled
      assert alethea(config, EmotionAnalyzer)[:base_url] == nil
    end

    test "emotion analyzer enabled requires its endpoint" do
      assert_raise RuntimeError, ~r/EMOTION_SIDECAR_URL is missing or empty/, fn ->
        prod_config(%{"EMOTION_ANALYZER_ENABLED" => "true"})
      end

      config =
        prod_config(%{
          "EMOTION_ANALYZER_ENABLED" => "true",
          "EMOTION_SIDECAR_URL" => "http://emotion.internal.test:8080"
        })

      assert alethea(config, :emotion_analyzer) == EmotionAnalyzer
      assert alethea(config, EmotionAnalyzer)[:base_url] == "http://emotion.internal.test:8080"
    end

    test "embeddings disabled" do
      assert prod_config() |> alethea(:ai_embeddings) == Embeddings.Disabled
    end

    test "embeddings enabled requires its endpoint" do
      assert_raise RuntimeError, ~r/EMBEDDINGS_BASE_URL is missing or empty/, fn ->
        prod_config(%{"EMBEDDINGS_ENABLED" => "true"})
      end

      config =
        prod_config(%{
          "EMBEDDINGS_ENABLED" => "true",
          "EMBEDDINGS_BASE_URL" => "http://embeddings.internal.test:11434"
        })

      assert alethea(config, :ai_embeddings) == Embeddings.Ollama

      assert alethea(config, Embeddings.Ollama)[:endpoint_url] ==
               "http://embeddings.internal.test:11434"
    end

    test "transcription is disabled and cannot be enabled without an adapter" do
      assert prod_config() |> alethea(:ai_whisper) == Whisper.Disabled

      assert prod_config(%{"WHISPER_ENABLED" => "false"}) |> alethea(:ai_whisper) ==
               Whisper.Disabled

      assert_raise RuntimeError, ~r/WHISPER_ENABLED.*no production transcription adapter/, fn ->
        prod_config(%{"WHISPER_ENABLED" => "true"})
      end
    end
  end

  describe "merged production configuration" do
    test "no Fake adapter and no localhost AI endpoint in any switch combination" do
      combinations = [
        %{},
        cloud_env(),
        %{
          "EMOTION_ANALYZER_ENABLED" => "true",
          "EMOTION_SIDECAR_URL" => "http://emotion.internal.test:8080",
          "EMBEDDINGS_ENABLED" => "true",
          "EMBEDDINGS_BASE_URL" => "http://embeddings.internal.test:11434"
        }
      ]

      for overrides <- combinations do
        merged = merged_prod_config(overrides)

        ai_config =
          Keyword.take(merged, [
            :emotion_analyzer,
            :ai_embeddings,
            :ai_whisper,
            :telegram_client,
            EmotionAnalyzer,
            Embeddings.Ollama,
            LLMConfig,
            GuidedConversationChain,
            ClinicalConsultationChain
          ])

        rendered = inspect(ai_config, limit: :infinity, printable_limit: :infinity)

        refute rendered =~ "localhost"
        refute rendered =~ "127.0.0.1"
        refute rendered =~ "Fake"

        for slot <- [:emotion_analyzer, :ai_embeddings, :ai_whisper] do
          assert Keyword.has_key?(merged, slot), "#{inspect(slot)} must never be left unset"
        end

        # The clinical consultation chain stays pinned to the local provider.
        assert merged[ClinicalConsultationChain][:provider] == :local
      end
    end
  end

  defp cloud_env(overrides \\ %{}) do
    Map.merge(
      %{
        "AI_PROVIDER" => "cloud",
        "LOCAL_LLM_BASE_URL" => nil,
        "OPENAI_API_KEY" => "synthetic-api-key",
        "LLM_MODEL" => "synthetic-hosted-model"
      },
      overrides
    )
  end

  defp prod_config(overrides \\ %{}) do
    runtime_path = Path.expand("config/runtime.exs")

    with_prod_env(overrides, fn -> Config.Reader.read!(runtime_path, env: :prod) end)
  end

  # Compile-time config (`config.exs` + `prod.exs`) merged with the runtime
  # config, which is what a booted release actually sees.
  defp merged_prod_config(overrides) do
    runtime_path = Path.expand("config/runtime.exs")
    compile_path = Path.expand("config/config.exs")

    with_prod_env(overrides, fn ->
      compile_path
      |> Config.Reader.read!(env: :prod)
      |> Config.Reader.merge(Config.Reader.read!(runtime_path, env: :prod))
      |> Keyword.fetch!(:alethea)
    end)
  end

  # Evaluates `fun` with exactly the synthetic production environment, from
  # an empty directory so the repository `.env` is never loaded.
  defp with_prod_env(overrides, fun) do
    original = Map.new(@managed_env, &{&1, System.get_env(&1)})

    empty_dir =
      Path.join(System.tmp_dir!(), "alethea-prod-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty_dir)
    Enum.each(@managed_env, &System.delete_env/1)

    @complete_env
    |> Map.merge(overrides)
    |> Enum.each(fn
      {_key, nil} -> :ok
      {key, value} -> System.put_env(key, value)
    end)

    try do
      File.cd!(empty_dir, fun)
    after
      File.rm_rf!(empty_dir)

      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp alethea(config, key) do
    config
    |> Keyword.fetch!(:alethea)
    |> Keyword.fetch!(key)
  end
end
