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

# Configure Cloak
config :alethea, Alethea.Encryption.Vault, aes_key: "lcCL8CL/9+jxk2PmCJwpmkKc1PrJ8nlO9NDhsh/6UKc="

config :alethea, Alethea.AI.PhiWorker,
  model: "phi-4-mini",
  stream: false,
  api_key: System.get_env("PHI_API_KEY")

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
