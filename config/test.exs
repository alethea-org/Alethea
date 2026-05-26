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

config :alethea, :phone_hash_secret, "dev_test_phone_hash_secret_key_32_bytes_minimum_length_fallback"

config :alethea, :whatsapp,
  api_token: "mock_token",
  phone_number_id: "mock_id"

config :alethea, :whatsapp_client, Alethea.WhatsApp.ClientMock

config :alethea, Oban, testing: :manual

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
