import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :alethea, Alethea.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "alethea_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :alethea, AletheaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o2ozvcdPxgM05dN6miy8UrRhvh4tbRBnG3d0T/XENsOUGOA6RVqSLHyaLooBBRgE",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzerMock
config :alethea, :phi_worker, Alethea.AI.PhiWorkerMock
config :alethea, :session_summary_chain, Alethea.AI.SessionSummaryChainMock
config :alethea, :weekly_summary_chain, Alethea.AI.WeeklySummaryChainMock

config :alethea, Alethea.AI.EmotionAnalyzer,
  base_url: "http://emotion-sidecar.test",
  connect_timeout: 100,
  receive_timeout: 100,
  max_batch_size: 32,
  max_text_bytes: 4096,
  req_options: [plug: {Req.Test, Alethea.AI.EmotionAnalyzer}]

config :alethea, Alethea.AI.Chains.GuidedConversationChain,
  api_key: "test_key",
  endpoint_url: "http://test.local/ai"

config :alethea, Oban,
  testing: :manual,
  repo: Alethea.Repo

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :alethea, :start_ai, false

# BotToken performs a fail-loud DB read in `init/1`; the supervisor
# process is not a SQL sandbox owner, so we skip the supervised child
# in `:test` (the test cases for BotToken start the GenServer manually
# with the sandbox explicitly allowed). The accessor is still exercised
# end-to-end in the test suite — see `Alethea.Telegram.BotTokenTest`.
config :alethea, :start_bot_token, false

# Pacer owns the rate-limit ETS tables. The PacerTest suite starts the
# GenServer explicitly per-test (to hermetic-ify the bucket state and
# override the test knobs without leaking across cases). We skip the
# supervised child in `:test` so the per-test `Pacer.start_link/1`
# doesn't hit a "name already registered" error.
config :alethea, :start_telegram_pacer, false

# Telegram Client adapter. The `Req` production adapter lands in
# PR #3a; the Fake is the test/dev no-op that accumulates sends in
# an ETS table. The outbound worker (PR #3a) reads this config at
# call-time and dispatches `send_message/2` to the chosen adapter.
config :alethea, :telegram_client, Alethea.Telegram.Client.Fake

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Test-only Vault encryption key — fixed value for deterministic test runs.
# NEVER use this value in production.
config :alethea, Alethea.Encryption.Vault, aes_key: "lcCL8CL/9+jxk2PmCJwpmkKc1PrJ8nlO9NDhsh/6UKc="

# AI adapter swap points (PR B of bootstrap-alethea-v2).
# The behaviours are the contract; the Fakes are the no-op adapters
# used in :test and :dev. Production adapters (HF Embeddings, Groq
# Whisper) are out of scope for bootstrap and land in their own
# changes (ai-embeddings-hf-foundation, etc.).
config :alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake
config :alethea, :ai_whisper, Alethea.AI.Whisper.Fake
