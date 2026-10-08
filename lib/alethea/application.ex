defmodule Alethea.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach Oban telemetry handlers
    Alethea.ObanTelemetry.attach()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Alethea.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc """
  The supervision tree, in start order, for the current application
  environment.

  `Alethea.Telegram.BotToken` starts right after the repo and the vault it
  reads through, and before Oban and the endpoint: a webhook request reaches
  `AletheaWeb.Plugs.TelegramSecretToken`, and an outbound job reaches the
  Telegram client, only once the sealed bot configuration is loaded. Shutdown
  runs in reverse, so the token outlives both.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    [
      AletheaWeb.Telemetry,
      Alethea.Repo,
      {DNSCluster, query: Application.get_env(:alethea, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Alethea.PubSub},
      Alethea.Encryption.Vault
    ] ++
      bot_token_children() ++
      [
        {Oban, Application.fetch_env!(:alethea, Oban)},
        AletheaWeb.Endpoint
      ] ++
      telegram_pacer_children() ++
      telegram_fake_children() ++
      ai_children()
  end

  defp bot_token_children do
    if Application.get_env(:alethea, :start_bot_token, true) do
      # BotToken performs a fail-loud DB read in `init/1`; the supervisor
      # process is not a SQL sandbox owner, so we skip the supervised child
      # in `:test` (the test cases for BotToken start the GenServer
      # manually with the sandbox explicitly allowed).
      [Alethea.Telegram.BotToken]
    else
      []
    end
  end

  defp telegram_pacer_children do
    if Application.get_env(:alethea, :start_telegram_pacer, true) do
      # Pacer owns the rate-limit ETS tables; in :test we start it
      # manually per test so the bucket state is hermetic. The
      # bot_token / pacer / ai gates are independent (the Pacer
      # is pure-ETS and does NOT touch the DB, so it could in
      # principle run under the supervisor in :test — but the
      # current PacerTest suite starts the GenServer explicitly
      # to control the config overrides; making the gate
      # independent keeps the test contract unchanged).
      [Alethea.Telegram.Pacer]
    else
      []
    end
  end

  defp telegram_fake_children do
    # The Fake GenServer backs the Fake adapter only, so it is supervised
    # exactly when that adapter is the configured Telegram client: the :dev
    # default for no-network smoke runs. Production configures the stateless
    # Req adapter and gets no Fake process. In :test the Fake is started
    # per-test via `start_supervised!`, under the same gate as the Pacer.
    if Application.get_env(:alethea, :start_telegram_pacer, true) and fake_telegram_client?() do
      [Alethea.Telegram.Client.Fake]
    else
      []
    end
  end

  # Resolved exactly like the workers resolve their adapter, including the
  # Fake fallback for a missing key.
  defp fake_telegram_client? do
    Application.get_env(:alethea, :telegram_client, Alethea.Telegram.Client.Fake) ==
      Alethea.Telegram.Client.Fake
  end

  defp ai_children do
    if Application.get_env(:alethea, :start_ai, true) do
      [Alethea.AI.ConversationMemory]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AletheaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
