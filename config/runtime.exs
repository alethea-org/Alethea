import Config

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

config :alethea, :crisis_patterns, %{
  immediate: [
    ~r/me voy a matar/iu,
    ~r/voy a suicidarme/iu,
    ~r/tengo (?:el|un) plan/iu,
    ~r/ya (?:lo|la) decid[ií]/iu
  ],
  high: [
    ~r/quiero morir/iu,
    ~r/no quiero (?:vivir|seguir)/iu,
    ~r/pienso en (?:el suicidio|hacerme da[ñn]o)/iu,
    ~r/me quiero hacer da[ñn]o/iu
  ],
  low: [
    ~r/a veces pienso que ser[ií]a mejor no estar/iu,
    ~r/no tiene sentido (?:seguir|vivir)/iu,
    ~r/est[oá]y harto de (?:todo|vivir)/iu
  ]
}

config :alethea, :crisis_support_message,
  """
  Entiendo que estás pasando por algo muy difícil. Lo que sientes importa.
  Por favor, comunícate con tu terapeuta directamente o llama a una línea de crisis:
  🇨🇱 Salud Responde: 600 360 7777 (24/7)
  🇨🇱 ACHS: 600 222 4357
  Si estás en peligro inmediato, llama al 131 (SAMU).
  """

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :alethea, Alethea.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
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

  host = System.get_env("PHX_HOST") || "example.com"

  config :alethea, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :alethea, AletheaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  phone_hash_secret =
    System.get_env("PHONE_HASH_SECRET") ||
      if config_env() == :prod do
        raise "environment variable PHONE_HASH_SECRET is missing."
      else
        "dev_test_phone_hash_secret_key_32_bytes_minimum_length_fallback"
      end

  config :alethea, :phone_hash_secret, phone_hash_secret

  config :alethea, :whatsapp,
    api_token: System.get_env("WHATSAPP_API_TOKEN", ""),
    phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID", ""),
    app_secret: System.get_env("WHATSAPP_APP_SECRET", "")

  ai_provider =
    System.get_env("AI_PROVIDER", "local")
    |> String.downcase()
    |> case do
      "cloud" -> :cloud
      _ -> :local
    end

  # Configuración compartida para chains de LangChain
  config :alethea, Alethea.AI.Chains.GuidedConversationChain,
    provider: ai_provider,
    cloud: [
      endpoint_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
      api_key: System.get_env("OPENAI_API_KEY", "")
    ],
    local: [
      endpoint_url: System.get_env("LOCAL_LLM_BASE_URL", "http://localhost:11434/v1"),
      api_key: System.get_env("LOCAL_LLM_API_KEY", "ollama")
    ]

  # Configuración para RoBERTa (Análisis de Emociones)
  roberta_provider =
    System.get_env("ROBERTA_PROVIDER", "local")
    |> String.downcase()
    |> case do
      "huggingface" -> :huggingface
      "hf" -> :huggingface
      _ -> :local
    end

  config :alethea, Alethea.AI.RoBERTaWorker,
    provider: roberta_provider,
    huggingface: [
      api_url: System.get_env("ROBERTA_HF_API_URL", "https://api-inference.huggingface.co/models/pysentimiento/robertuito-emotion-analysis"),
      api_key: System.get_env("ROBERTA_HF_API_KEY", "")
    ]

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
