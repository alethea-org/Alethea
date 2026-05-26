# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :alethea,
  ecto_repos: [Alethea.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :alethea, AletheaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AletheaWeb.ErrorHTML, json: AletheaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Alethea.PubSub,
  live_view: [signing_salt: "AWk2c+oE"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Oban
config :alethea, Oban,
  engine: Oban.Engines.Basic,
  queues: [default: 10, whatsapp: 20],
  repo: Alethea.Repo

config :alethea, Alethea.AI.Chains.GuidedConversationChain,
  model: "phi-4-mini",
  system_prompt: """
  Eres un asistente clínico de apoyo. Tu única función es escuchar y formular
  preguntas exploratorias con tono socrático.
  PROHIBIDO: emitir diagnósticos, validar o refutar pensamientos del paciente,
  dar consejos médicos directos o sugerir tratamientos.
  (Nota: El control de crisis y el envío del mensaje de soporte ante riesgo de daño propio/terceros se realiza en una capa perimetral/bypass previa, utilizando el mensaje configurado en `:crisis_support_message`.)
  """

# Configure Cloak
config :alethea, Alethea.Encryption.Vault, aes_key: "lcCL8CL/9+jxk2PmCJwpmkKc1PrJ8nlO9NDhsh/6UKc="

config :alethea, Alethea.AI.Chains.GuidedConversationChain,
  provider: :local,
  model: System.get_env("HUGGINGFACE_MODEL", "phi-4-mini"),
  stream: false,
  temperature: 0.0,
  max_tokens: 512,
  local: [
    endpoint: System.get_env("HUGGINGFACE_API_URL", "https://api-inference.huggingface.co/models"),
    api_key: System.get_env("HUGGINGFACE_API_KEY", "")
  ],
  system_prompt: """
  Eres un asistente clínico de apoyo. Tu única función es escuchar y formular
  preguntas exploratorias con tono socrático.
  PROHIBIDO: emitir diagnósticos, validar o refutar pensamientos del paciente,
  dar consejos médicos directos o sugerir tratamientos.
  (Nota: El control de crisis y el envío del mensaje de soporte ante riesgo de daño propio/terceros se realiza en una capa perimetral/bypass previa, utilizando el mensaje configurado en `:crisis_support_message`.)
  """

config :alethea, Alethea.Clinical,
  recent_message_limit: 10

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
