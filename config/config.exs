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
#
# Telegram queues (PR #2):
#   - `telegram_inbound` (TASK-2-3) — the webhook controller enqueues
#     `TelegramMessageWorker` + `TelegramOnboardingWorker` here. Shared
#     queue; the routing decision (message vs onboarding) lives at the
#     controller level, not the queue level.
#   - `telegram_outbound` (TASK-2-6) — the safe-path outbound worker
#     (`TelegramOutboundWorker`) consumes from this queue. The actual
#     worker lands in PR #3a; the queue is registered here so PR #3a
#     can `:use Oban.Worker, queue: :telegram_outbound` without a config
#     delta.
#   - `telegram_outbound_crisis` (PR #3b) — the crisis-bypass priority
#     lane. Higher priority than `telegram_outbound` so a crisis message
#     is not blocked by a backlog of safe-path replies. The worker lands
#     in PR #3b; the queue is registered here for the same reason.
config :alethea, Oban,
  engine: Oban.Engines.Basic,
  queues: [
    default: 10,
    sessions: 10,
    schedulers: 5,
    reports: 5,
    ai_analysis: 5,
    telegram_inbound: 10,
    telegram_outbound: 10,
    # `telegram_outbound_crisis` (REQ-C7-crisis-priority-lane; PR #3b /
    # TASK-3b-2) is a dedicated queue for crisis-bypass replies. Two
    # notes about its priority semantics:
    #
    # 1. **Open-source Oban 2.x does NOT honor `max_demand` or
    #    `priority` at the queue level** — these options are silently
    #    absorbed into the queue meta dict but never consulted by
    #    `Oban.Engines.Basic` (`deps/oban/lib/oban/engines/basic.ex`).
    #    Honoring them requires `Oban.Pro` (not in `mix.lock`). The
    #    `limit: 10` value below caps total concurrency for the
    #    crisis queue; for true per-lane throttling or priority
    #    weighting, plan an Oban Pro migration (follow-up issue).
    #
    # 2. **In Oban's job-level priority, lower numbers = higher
    #    priority** (0 is highest, 9 is lowest — see
    #    `deps/oban/lib/oban/worker.ex`). The inbound worker
    #    (`TelegramMessageWorker.enqueue_outbound/6`) sets
    #    `priority: 0` on crisis jobs so they outrank the safe
    #    queue's default `priority: 9` (set at the worker level via
    #    `use Oban.Worker, queue: :telegram_outbound`).
    #
    # Until Oban Pro lands, the "crisis priority lane" contract is
    # enforced at the **job-level priority** (set in
    # `TelegramMessageWorker.enqueue_outbound/6`), not the queue
    # level. The crisis queue is throttled to `5` (vs the safe
    # queue's `10`) as a soft pre-Oban-Pro approximation of the
    # spec's "dedicated priority lane" — the real isolation comes
    # from job-level priority (0 vs 9), not queue-level limits.
    telegram_outbound_crisis: 5
  ],
  repo: Alethea.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 0 * * *", AletheaJobs.DailySchedulerWorker}
     ]}
  ]

# Telegram Pacer (PR #2 TASK-2-6). The Pacer is a singleton GenServer
# that owns the rate-limit ETS tables. It is started under the
# application supervisor in `dev` and `prod`; in `test` it is started
# manually per-test (mirrors the `start_bot_token` gate) so each test
# gets a fresh bucket state.
config :alethea, :start_telegram_pacer, true

# Telegram Client adapter (PR #3a / TASK-3a-4). Defaults to the
# Req production adapter for prod (config/config.exs); the `:test`
# and `:dev` env configs override to the Fake (no-op accumulator
# adapter that records sends in an ETS table). The behaviour
# contract `Alethea.Telegram.Client` is what every consumer codes
# against — the adapter swap is config-only.
config :alethea, :telegram_client, Alethea.Telegram.Client.Req

# --- AI & Clinical Configuration ---

config :alethea, Alethea.Clinical, recent_message_limit: 10

# Global configuration for LangChain chains
config :alethea, Alethea.AI.Chains.GuidedConversationChain,
  provider: :local,
  model: System.get_env("LLM_MODEL", "phi4-mini"),
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

config :alethea, Alethea.AI.EmotionAnalyzer,
  base_url: "http://127.0.0.1:8080",
  connect_timeout: 2_000,
  receive_timeout: 30_000,
  max_batch_size: 32,
  max_text_bytes: 4096

# --- Security & Encryption ---

# Vault aes_key is loaded from the CLOAK_AES_KEY environment variable in runtime.exs.
# Dev/test fallbacks are defined in dev.exs and test.exs respectively.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
