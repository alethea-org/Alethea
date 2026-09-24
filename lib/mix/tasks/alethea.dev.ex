defmodule Mix.Tasks.Alethea.Dev do
  @shortdoc "Development only: starts local Postgres if Neon is unreachable, then phx.server"

  @moduledoc """
  Development environment only. Runs the app outside Docker with automatic
  database selection (see `Alethea.DevDatabase`):

      mix alethea.dev

  1. Loads the runtime config, which probes the shared Neon database.
  2. If Neon is unreachable (e.g. port 5432 blocked on the university wifi),
     starts the local Postgres container with `docker compose up -d --wait db`.
  3. Applies pending migrations and starts `phx.server`.

  First run against a fresh local database also needs the seeds:
  `mix ecto.setup` and `mix run priv/repo/seeds_team.exs`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :dev do
      Mix.raise("mix alethea.dev is development-only (current env: #{Mix.env()})")
    end

    Mix.Task.run("app.config")

    if Application.get_env(:alethea, :dev_database_source) == :local do
      start_local_database()
    end

    Mix.Task.run("ecto.migrate")
    Mix.Task.run("phx.server", args)
  end

  defp start_local_database do
    Mix.shell().info("[dev] Neon unreachable: starting local Postgres (docker compose)...")

    case System.cmd("docker", ~w(compose up -d --wait db), stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise("""
        Could not start the local Postgres container (exit #{status}):

        #{output}
        """)
    end
  end
end
