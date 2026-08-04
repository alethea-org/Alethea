defmodule Alethea.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach Oban telemetry handlers
    Alethea.ObanTelemetry.attach()

    children = [
      AletheaWeb.Telemetry,
      Alethea.Repo,
      {DNSCluster, query: Application.get_env(:alethea, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Alethea.PubSub},
      Alethea.Encryption.Vault,
      {Oban, Application.fetch_env!(:alethea, Oban)},
      AletheaWeb.Endpoint
    ]

    children =
      if Application.get_env(:alethea, :start_bot_token, true) do
        # BotToken performs a fail-loud DB read in `init/1`; the supervisor
        # process is not a SQL sandbox owner, so we skip the supervised child
        # in `:test` (the test cases for BotToken start the GenServer
        # manually with the sandbox explicitly allowed).
        children ++ [Alethea.Telegram.BotToken]
      else
        children
      end

    children =
      if Application.get_env(:alethea, :start_telegram_pacer, true) do
        # Pacer owns the rate-limit ETS tables; in :test we start it
        # manually per test so the bucket state is hermetic. The
        # bot_token / pacer / ai gates are independent (the Pacer
        # is pure-ETS and does NOT touch the DB, so it could in
        # principle run under the supervisor in :test — but the
        # current PacerTest suite starts the GenServer explicitly
        # to control the config overrides; making the gate
        # independent keeps the test contract unchanged).
        children ++ [Alethea.Telegram.Pacer]
      else
        children
      end

    children =
      if Application.get_env(:alethea, :start_telegram_pacer, true) do
        # The Telegram Client Fake GenServer is started under the
        # same gate as the Pacer (the Fake is used in :dev for
        # no-network smoke runs; in :test the Fake is started
        # per-test via `start_supervised!` to hermetic-ify the
        # ETS). The production Req adapter (PR #3a) will not need
        # this supervision — it is a stateless HTTP client.
        children ++ [Alethea.Telegram.Client.Fake]
      else
        children
      end

    children =
      if Application.get_env(:alethea, :start_ai, true) do
        children ++ [Alethea.AI.RoBERTaWorker, Alethea.AI.ConversationMemory]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Alethea.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AletheaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
