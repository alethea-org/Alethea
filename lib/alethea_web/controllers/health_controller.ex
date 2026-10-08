defmodule AletheaWeb.HealthController do
  @moduledoc """
  Health check controller for platform probes.

  - `/health`: liveness probe. Touches no dependency, so a database outage
    never makes the platform restart a process that is otherwise alive.
  - `/health/ready`: readiness probe. Returns 200 only when the database
    answers and Oban is running and can reach its jobs table; 503 otherwise.

  The response carries one status per dependency and nothing else. Failure
  reasons are deliberately dropped: a database error can embed the connection
  string, and this endpoint is unauthenticated.

  ## Test seam

  `config :alethea, :health_checks` accepts `:query` (a one-arity function
  taking SQL, default `Alethea.Repo.query/1`) and `:oban_name` (default
  `Oban`). Production never sets it.
  """

  use AletheaWeb, :controller

  alias Alethea.Repo

  @database_sql "SELECT 1"
  @oban_sql "SELECT 1 FROM oban_jobs LIMIT 1"

  def liveness(conn, _params) do
    conn
    |> put_status(200)
    |> json(%{status: "ok"})
  end

  def readiness(conn, _params) do
    overrides = Application.get_env(:alethea, :health_checks, [])
    query = Keyword.get(overrides, :query, &Repo.query/1)
    oban_name = Keyword.get(overrides, :oban_name, Oban)

    checks = %{
      database: check_database(query),
      oban: check_oban(query, oban_name)
    }

    status =
      if checks.database == :ok and checks.oban == :ok do
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

  defp check_database(query), do: run_query(query, @database_sql)

  # Oban is ready when its supervisor is running and the jobs table it stores
  # work in is reachable. The process check alone would pass while the table
  # is missing or the database is gone; the query alone would pass with no
  # Oban instance at all. Queue producers are not inspected: with
  # `testing: :manual` Oban legitimately runs none.
  defp check_oban(query, oban_name) do
    if oban_running?(oban_name) do
      run_query(query, @oban_sql)
    else
      :error
    end
  end

  defp oban_running?(oban_name) do
    case Oban.whereis(oban_name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _not_running -> false
    end
  end

  # Any outcome other than `{:ok, _}` is a failed check: an error tuple, an
  # exception, or an exit from a pool that is not running. The reason is
  # discarded on purpose (see the moduledoc).
  defp run_query(query, sql) do
    case query.(sql) do
      {:ok, _result} -> :ok
      _error -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end
end
