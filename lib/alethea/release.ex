defmodule Alethea.Release do
  @moduledoc """
  Release tasks, callable without Mix installed.

      bin/alethea eval "Alethea.Release.migrate"
      bin/alethea eval "Alethea.Release.rollback(Alethea.Repo, 20260618234145)"

  `bin/migrate` wraps the first form. Neither function runs seeds: seeding a
  deployed database is a separate, explicit operation.

  ## What a run needs

  `bin/alethea eval` evaluates `config/runtime.exs` before this module runs, so
  every variable that file requires in `:prod` must be set even though only the
  repo is started. `load_app/0` then loads the application environment without
  starting the supervision tree, which is what migrations reading application
  config rely on (the Telegram chat id backfill reads
  `:telegram_chat_id_pepper`).

  Migrations that disable the migration lock or the DDL transaction are only
  safe with a single migrator, so run this from one place per deploy.
  """

  @app :alethea

  @doc "Runs every pending migration for each configured repo."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _migrated, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back to `version`."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _rolled_back, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # Database TLS needs the :ssl application started before the repo connects.
    {:ok, _started} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
