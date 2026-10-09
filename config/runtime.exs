import Config

Alethea.RuntimeEnv.load_dotenv(".env")

if config_env() == :dev do
  # Development environment only: pick the database after .env is loaded
  # (dev.exs runs before it). Uses the shared Neon database when its port is
  # reachable, otherwise the local Docker Postgres. See Alethea.DevDatabase.
  {dev_db_source, dev_db_url} = Alethea.DevDatabase.select(System.get_env())

  IO.puts(
    :stderr,
    "[dev] Database: #{dev_db_source} (#{Alethea.DevDatabase.redact(dev_db_url)})"
  )

  config :alethea, Alethea.Repo, url: dev_db_url
  config :alethea, :dev_database_source, dev_db_source

  # The running summary (#394) follows the guided chain's local model
  # (LLM_MODEL) and the local endpoint set in config/dev.exs.
  config :alethea,
         Alethea.AI.Chains.RunningSummaryChain,
         [provider: :local] ++
           if(model = System.get_env("LLM_MODEL"), do: [model: model], else: [])

  telegram_client =
    case System.get_env("TELEGRAM_CLIENT_ADAPTER") do
      "req" -> Alethea.Telegram.Client.Req
      _ -> Alethea.Telegram.Client.Fake
    end

  config :alethea, :telegram_client, telegram_client
end

if config_env() in [:dev, :prod] do
  real_telegram_client? =
    config_env() == :prod or System.get_env("TELEGRAM_CLIENT_ADAPTER") == "req"

  case System.get_env("TELEGRAM_CHAT_ID_PEPPER") do
    pepper when is_binary(pepper) and byte_size(pepper) > 0 ->
      if String.trim(pepper) == "" and real_telegram_client? do
        raise "TELEGRAM_CHAT_ID_PEPPER is missing or empty while the real Telegram client is enabled"
      end

      if String.trim(pepper) != "", do: config(:alethea, :telegram_chat_id_pepper, pepper)

    _missing ->
      if real_telegram_client? do
        raise "TELEGRAM_CHAT_ID_PEPPER is missing or empty while the real Telegram client is enabled"
      end
  end
end

if config_env() in [:dev, :prod] do
  config :alethea, Alethea.AI.EmotionAnalyzer,
    connect_timeout:
      String.to_integer(System.get_env("EMOTION_SIDECAR_CONNECT_TIMEOUT_MS", "2000")),
    receive_timeout:
      String.to_integer(System.get_env("EMOTION_SIDECAR_RECEIVE_TIMEOUT_MS", "30000")),
    max_batch_size: String.to_integer(System.get_env("EMOTION_SIDECAR_MAX_BATCH_SIZE", "32")),
    max_text_bytes: String.to_integer(System.get_env("EMOTION_SIDECAR_MAX_TEXT_BYTES", "4096"))
end

# The loopback sidecar default exists only for the local :dev workflow
# (`docker compose up -d emotion-sidecar`). Production has no default
# endpoint: the :prod block below either requires EMOTION_SIDECAR_URL or
# wires the explicit `Disabled` adapter (issue #402).
if config_env() == :dev do
  config :alethea, Alethea.AI.EmotionAnalyzer,
    base_url: System.get_env("EMOTION_SIDECAR_URL", "http://127.0.0.1:8080")
end

# Issue #198 — the emotion analyzer is a development-only capability with
# no clinical-validity claim. Issue #402 makes its production state
# explicit: the :prod block below wires the :emotion_analyzer slot either
# to the sidecar adapter (EMOTION_ANALYZER_ENABLED=true plus its endpoint)
# or to `Alethea.AI.EmotionAnalyzer.Disabled`. Whether a deployment enables
# it is a product decision, not a default.

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/alethea start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :alethea, AletheaWeb.Endpoint, server: true
end

config :alethea, AletheaWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

database_monitoring_enabled? =
  String.downcase(System.get_env("DB_MONITORING_ENABLED", "true")) in ~w(true 1 yes y on)

config :alethea, :database_monitoring,
  enabled: database_monitoring_enabled?,
  slow_query_threshold_ms:
    String.to_integer(System.get_env("DB_SLOW_QUERY_THRESHOLD_MS", "1000")),
  pool_queue_warn_ms: String.to_integer(System.get_env("DB_POOL_QUEUE_WARN_MS", "100")),
  pool_queue_length_warn: String.to_integer(System.get_env("DB_POOL_QUEUE_LENGTH_WARN", "1")),
  query_log_max_chars: String.to_integer(System.get_env("DB_QUERY_LOG_MAX_CHARS", "4000"))

# Crisis patterns are configured directly in Alethea.Alerts.CrisisMonitor.default_patterns/0
# to avoid duplication. Override via app env only if needed for testing.

config :alethea, :crisis_support_message, """
Entiendo que estás pasando por algo muy difícil. Lo que sientes importa.
Por favor, comunícate con tu terapeuta directamente o llama a una línea de crisis:
🇨🇱 Salud Responde: 600 360 7777 (24/7)
🇨🇱 ACHS: 600 222 4357
Si estás en peligro inmediato, llama al 131 (SAMU).
"""

if config_env() == :prod do
  # Environment readers for the production contract (issue #402). A blank
  # value counts as missing, and no error message echoes a value: these
  # variables carry credentials.
  optional_env = fn name ->
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
    end
  end

  required_env = fn name, hint ->
    optional_env.(name) || raise "environment variable #{name} is missing or empty. #{hint}"
  end

  positive_integer_env = fn name, default ->
    case Integer.parse(System.get_env(name, default)) do
      {value, ""} when value > 0 -> value
      _other -> raise "environment variable #{name} must be a positive integer."
    end
  end

  # An AI capability is never enabled or disabled by omission: the switch
  # must be present and must be exactly `true` or `false`.
  capability_switch = fn name ->
    case System.get_env(name) do
      "true" ->
        true

      "false" ->
        false

      nil ->
        raise "environment variable #{name} is missing. " <>
                "Set it explicitly to true or false."

      _other ->
        raise "environment variable #{name} must be exactly true or false."
    end
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # Ecto merges the options it parses from the URL over the Repo
  # configuration, and `ssl` is one of them: `?ssl=false` would replace the
  # verified TLS setting below. The parameter is refused in any letter case
  # and with any value, so DATABASE_SSL is the only switch. The message
  # never includes the URL, which holds the password.
  database_url_parameters =
    case URI.parse(database_url).query do
      nil -> []
      query -> query |> URI.query_decoder() |> Enum.map(fn {name, _value} -> name end)
    end

  if Enum.any?(database_url_parameters, &(String.downcase(&1) == "ssl")) do
    raise "environment variable DATABASE_URL must not carry an `ssl` query parameter. " <>
            "Remove it: database TLS is controlled only by the DATABASE_SSL variable."
  end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Database TLS is on by default and verified. Postgrex merges a keyword
  # `:ssl` over its own defaults (`verify: :verify_peer` plus the HTTPS
  # hostname check) and derives SNI from the hostname, so passing the OS
  # trust store is the whole configuration. Ecto passes `sslmode=` and
  # `channel_binding=` from the URL through without effect, and the `ssl`
  # parameter, the one URL option that would override this, is refused above.
  #
  # DATABASE_SSL=false is the only opt-out and exists for a local release
  # smoke test against a Postgres without TLS. Only that exact literal
  # disables it; any other value, including a typo, keeps TLS on.
  database_ssl =
    case System.get_env("DATABASE_SSL") do
      "false" -> false
      _on -> [cacerts: :public_key.cacerts_get()]
    end

  # Connect and handshake share one budget: a suspended Neon compute needs
  # a few hundred milliseconds to resume, and Neon recommends 10-15 s.
  database_connect_timeout = positive_integer_env.("DATABASE_CONNECT_TIMEOUT_MS", "15000")

  config :alethea, Alethea.Repo,
    ssl: database_ssl,
    url: database_url,
    # Neon's direct (non-pooler) host has a small connection budget and
    # every Machine opens its own pool, so the default stays small.
    pool_size: positive_integer_env.("POOL_SIZE", "5"),
    # Postgrex: TCP connect and TLS/authentication handshake timeouts.
    connect_timeout: database_connect_timeout,
    handshake_timeout: database_connect_timeout,
    # DBConnection: callers may wait up to `queue_target` for a connection
    # before the pool starts shedding load, measured over `queue_interval`.
    # The 50 ms default would drop requests while the pool reconnects after
    # a compute suspend.
    queue_target: positive_integer_env.("DATABASE_QUEUE_TARGET_MS", "2000"),
    queue_interval: positive_integer_env.("DATABASE_QUEUE_INTERVAL_MS", "10000"),
    # DBConnection: reconnect with randomized exponential backoff, capped
    # well below the 30 s default so a resumed compute is picked up quickly.
    backoff_type: :rand_exp,
    backoff_min: 500,
    backoff_max: 10_000,
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The public host has no default: URL generation, HSTS redirects and the
  # LiveView origin check all depend on it.
  host = required_env.("PHX_HOST", "Set it to the public host name, for example app.example.org.")

  if String.contains?(host, ["/", ":"]) do
    raise "environment variable PHX_HOST must be a bare host name, without scheme, port or path."
  end

  # Extra allowed origins (for example a custom domain in front of the
  # platform host), as a comma-separated list of full origins.
  extra_origins =
    System.get_env("PHX_EXTRA_ORIGINS", "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :alethea, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The URL Telegram delivers updates to. It is only ever sent to Telegram by
  # the explicit `bin/telegram_bootstrap register-webhook` operation; booting
  # or migrating never registers it. The path is the webhook route in
  # `AletheaWeb.Router` (`Alethea.Telegram.WebhookRegistration.webhook_path/0`).
  config :alethea, :telegram_webhook_url, "https://" <> host <> "/webhooks/telegram"

  config :alethea, AletheaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://" <> host | extra_origins],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  cloak_aes_key =
    System.get_env("CLOAK_AES_KEY") ||
      raise """
      environment variable CLOAK_AES_KEY is missing.
      Generate one with: mix run -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'
      """

  config :alethea, Alethea.Encryption.Vault, aes_key: cloak_aes_key

  # ## LLM provider (issue #402)
  #
  # AI_PROVIDER selects the provider of the guided conversation chain and
  # must be set explicitly. It does not move any other chain: those keep
  # the provider they are pinned to (`:local` unless configured otherwise),
  # so clinical narrative is never rerouted to a hosted model by this
  # variable.
  ai_provider =
    case System.get_env("AI_PROVIDER") do
      "local" ->
        :local

      "cloud" ->
        :cloud

      nil ->
        raise "environment variable AI_PROVIDER is missing. Set it explicitly to local or cloud."

      _other ->
        raise "environment variable AI_PROVIDER has an unsupported value. " <>
                "Supported values: local, cloud."
    end

  local_llm_base_url = optional_env.("LOCAL_LLM_BASE_URL")
  openai_api_key = optional_env.("OPENAI_API_KEY")
  llm_model = optional_env.("LLM_MODEL")

  if ai_provider == :local and is_nil(local_llm_base_url) do
    raise "environment variable LOCAL_LLM_BASE_URL is missing or empty. " <>
            "It is required while AI_PROVIDER=local."
  end

  if ai_provider == :cloud and is_nil(openai_api_key) do
    raise "environment variable OPENAI_API_KEY is missing or empty. " <>
            "It is required while AI_PROVIDER=cloud."
  end

  # The compiled default model is a local model name; a hosted provider
  # must name its own.
  if ai_provider == :cloud and is_nil(llm_model) do
    raise "environment variable LLM_MODEL is missing or empty. " <>
            "It is required while AI_PROVIDER=cloud."
  end

  # Global endpoints, shared by every chain through `Alethea.AI.LLMConfig`.
  # A provider without an endpoint or key stays absent here, and
  # `LLMConfig` resolves it to "not configured" in production instead of a
  # localhost default.
  config :alethea, Alethea.AI.LLMConfig,
    local: if(local_llm_base_url, do: [endpoint_url: local_llm_base_url], else: []),
    cloud:
      [endpoint_url: optional_env.("OPENAI_BASE_URL") || "https://api.openai.com/v1"] ++
        if(openai_api_key, do: [api_key: openai_api_key], else: [])

  config :alethea,
         Alethea.AI.Chains.GuidedConversationChain,
         [provider: ai_provider] ++ if(llm_model, do: [model: llm_model], else: [])

  # The running summary (#394) is pinned to the local provider whatever
  # AI_PROVIDER says, so clinical narrative never reaches a hosted model. It
  # shares the guided model only while that chain is local too; otherwise it
  # keeps the compiled local default, never the hosted model name. Without
  # LOCAL_LLM_BASE_URL it has no endpoint and stays disabled
  # (`Alethea.Clinical.RunningSummary.enabled?/0`).
  config :alethea,
         Alethea.AI.Chains.RunningSummaryChain,
         [provider: :local] ++
           if(ai_provider == :local and llm_model, do: [model: llm_model], else: [])

  # ## AI capability switches (issue #402)
  #
  # Each discovery slot of `Alethea.AI` is either enabled with its endpoint
  # or wired to its `Disabled` adapter. No slot is left unset and no Fake
  # adapter is selectable here.
  if capability_switch.("EMOTION_ANALYZER_ENABLED") do
    config :alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzer

    config :alethea, Alethea.AI.EmotionAnalyzer,
      base_url:
        required_env.(
          "EMOTION_SIDECAR_URL",
          "It is required while EMOTION_ANALYZER_ENABLED=true."
        )
  else
    config :alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzer.Disabled
    # Clears the loopback default compiled in from config/config.exs.
    config :alethea, Alethea.AI.EmotionAnalyzer, base_url: nil
  end

  if capability_switch.("EMBEDDINGS_ENABLED") do
    embeddings_endpoint =
      [
        endpoint_url:
          required_env.("EMBEDDINGS_BASE_URL", "It is required while EMBEDDINGS_ENABLED=true.")
      ]

    # The adapter's own default model (bge-m3) applies unless overridden.
    embeddings_model =
      if model = optional_env.("EMBEDDINGS_MODEL"), do: [model: model], else: []

    config :alethea, :ai_embeddings, Alethea.AI.Embeddings.Ollama
    config :alethea, Alethea.AI.Embeddings.Ollama, embeddings_endpoint ++ embeddings_model
  else
    config :alethea, :ai_embeddings, Alethea.AI.Embeddings.Disabled
  end

  # Transcription has no production adapter yet (only the Fake exists), so
  # it is always disabled and asking for it fails the boot.
  case System.get_env("WHISPER_ENABLED") do
    value when value in [nil, "false"] ->
      config :alethea, :ai_whisper, Alethea.AI.Whisper.Disabled

    "true" ->
      raise "environment variable WHISPER_ENABLED cannot be true: " <>
              "no production transcription adapter exists yet. Unset it or set it to false."

    _other ->
      raise "environment variable WHISPER_ENABLED must be exactly true or false."
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :alethea, AletheaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :alethea, AletheaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
