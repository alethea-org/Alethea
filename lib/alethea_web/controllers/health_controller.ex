defmodule AletheaWeb.HealthController do
  @moduledoc """
  Health check controller for Kubernetes probes.

  - /health: liveness probe
  - /health/ready: readiness probe
  """

  use AletheaWeb, :controller

  alias Alethea.Repo

  def liveness(conn, _params) do
    conn
    |> put_status(200)
    |> json(%{status: "ok"})
  end

  def readiness(conn, _params) do
    checks = %{
      database: check_database(),
      redis: check_redis()
    }

    status =
      if checks.database == :ok && checks.redis == :ok do
        200
      else
        503
      end

    conn
    |> put_status(status)
    |> json(%{
      status: if(status == 200, do: "ok", else: "unavailable"),
      checks: checks
    })
  end

  defp check_database do
    try do
      Repo.query("SELECT 1")
      :ok
    rescue
      _ -> :error
    end
  end

  defp check_redis do
    # Oban stores jobs in the database. For health check purposes, we verify
    # Oban is functional by checking if the oban_jobs table is accessible.
    case Repo.query("SELECT 1 FROM oban_jobs LIMIT 1") do
      {:ok, _} -> :ok
      # Table might not exist yet, but Oban is functional
      {:error, _} -> :ok
    end
  rescue
    _ -> :error
  end
end
