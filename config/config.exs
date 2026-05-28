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
  queues: [default: 10, whatsapp: 20, sessions: 10, schedulers: 5, reports: 5],
  repo: Alethea.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 0 * * *", AletheaJobs.DailySchedulerWorker}
     ]}
  ]

# --- AI & Clinical Configuration ---

config :alethea, Alethea.Clinical, recent_message_limit: 10

# Global configuration for LangChain chains
config :alethea, Alethea.AI.Chains.GuidedConversationChain,
  provider: :local,
  model: System.get_env("LLM_MODEL", "phi-4-mini"),
  stream: false,
  temperature: 0.0,
  max_tokens: 512,
  system_prompt: """
  Eres Alethea, un asistente clínico de apoyo socrático.
  TU ROL: Escuchar activamente y formular preguntas breves que inviten a la reflexión.
  REGLAS DE ORO (INNEGOCIABLES):
  1. PROHIBIDO emitir diagnósticos o etiquetas clínicas.
  2. PROHIBIDO dar consejos médicos, sugerir medicación o tratamientos.
  3. NO valides ni refutes pensamientos distorsionados; en su lugar, pregunta "¿Qué evidencia tienes para pensar eso?" o "¿Hay otra forma de ver esto?".
  4. Mantén un tono empático pero profesional y neutral.
  5. Si detectas riesgo inminente, el sistema perimetral ya actuó, tú continúa con el proceso reflexivo calmado.
  """

config :alethea, Alethea.AI.RoBERTaWorker,
  api_url:
    "https://api-inference.huggingface.co/models/pysentimiento/robertuito-emotion-analysis",
  api_key: System.get_env("HUGGINGFACE_API_KEY")

# --- Security & Encryption ---

# Vault aes_key is loaded from the CLOAK_AES_KEY environment variable in runtime.exs.
# Dev/test fallbacks are defined in dev.exs and test.exs respectively.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
