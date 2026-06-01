defmodule Alethea.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AletheaWeb.Telemetry,
      Alethea.Repo,
      {DNSCluster, query: Application.get_env(:alethea, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Alethea.PubSub},
      Alethea.Encryption.Vault,
      Alethea.WhatsApp.ConsentCache,
      Alethea.RateLimiter,
      {Oban, Application.fetch_env!(:alethea, Oban)},
      AletheaWeb.Endpoint
    ]

    children =
      if Application.get_env(:alethea, :start_ai, true) do
        children ++ [Alethea.AI.RoBERTaWorker]
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
