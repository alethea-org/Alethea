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

  ## Telegram

      bin/alethea eval "Alethea.Release.telegram_bootstrap"
      bin/alethea eval "Alethea.Release.telegram_register_webhook"

  `bin/telegram_bootstrap` wraps both: with no argument it runs the first,
  and with the explicit `register-webhook` argument it runs the second.

  `telegram_bootstrap/0` writes the sealed `BotConfig` row for this build's
  environment from `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET` and
  `TELEGRAM_BOT_USERNAME`. It only talks to the database, is idempotent, and
  must run after `migrate/0` and before the server boots, because
  `Alethea.Telegram.BotToken` refuses to start without that row.

  `telegram_register_webhook/0` calls Telegram (`setWebhook`, verified with
  `getWebhookInfo`) using the stored row and the configured
  `:telegram_webhook_url`. It is an external side effect, so nothing runs it
  implicitly: not `migrate/0`, not `telegram_bootstrap/0`, not the server.

  Both start only the repo, the encryption vault and, for the registration,
  the HTTP client; the endpoint and Oban never start. Both raise on failure,
  which makes `bin/alethea eval` exit non-zero, and the raised message is a
  fixed line without the token or the secret.
  """

  alias Alethea.Encryption.Vault
  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Telegram.Bootstrap
  alias Alethea.Telegram.WebhookRegistration

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

  @doc """
  Writes the sealed Telegram `BotConfig` row for this build's environment.

  Prints one non-secret line and returns `:ok`; raises on failure.
  """
  @spec telegram_bootstrap() :: :ok
  def telegram_bootstrap do
    load_app()
    env = build_env()

    case with_services([], fn -> Bootstrap.run(env, System.get_env()) end) do
      {:ok, %{status: status, bot_username: bot_username}} ->
        IO.puts("TELEGRAM_BOT_CONFIG env=#{env} status=#{status} username=#{bot_username}")

      {:error, reason} ->
        raise "TELEGRAM_BOOTSTRAP_FAILED env=#{env} reason=#{bootstrap_failure(reason)}"
    end
  end

  @doc """
  Registers the Telegram webhook for this build's environment and verifies
  it. Calls the Telegram Bot API.

  Prints one non-secret line and returns `:ok`; raises on failure.
  """
  @spec telegram_register_webhook() :: :ok
  def telegram_register_webhook do
    load_app()
    env = build_env()

    case with_services([:req], fn -> register_webhook(env) end) do
      {:ok,
       %{status: status, webhook_url: url, allowed_updates: updates, pending_update_count: n}} ->
        IO.puts(
          "TELEGRAM_WEBHOOK env=#{env} status=#{status} url=#{url} " <>
            "allowed_updates=#{Enum.join(updates, ",")} pending_update_count=#{n}"
        )

      {:error, reason} ->
        raise "TELEGRAM_WEBHOOK_REGISTRATION_FAILED env=#{env} reason=#{webhook_failure(reason)}"
    end
  end

  defp register_webhook(env) do
    with {:ok, webhook_url} <- configured_webhook_url(),
         {:ok, %BotConfig{bot_token: bot_token, secret_token: secret_token}}
         when is_binary(bot_token) and is_binary(secret_token) <-
           BotConfig.for_env(env, log: false) do
      WebhookRegistration.register(bot_token, secret_token, webhook_url)
    else
      {:error, reason} -> {:error, reason}
      # `:not_found`, or a row that did not decrypt to binaries. The row is
      # never rendered.
      _other -> {:error, :bot_config_missing}
    end
  end

  defp configured_webhook_url do
    case Application.fetch_env(@app, :telegram_webhook_url) do
      {:ok, url} when is_binary(url) and url != "" -> {:ok, url}
      _other -> {:error, :webhook_url_not_configured}
    end
  end

  defp bootstrap_failure({:crashed, module}), do: "unexpected failure (#{inspect(module)})"
  defp bootstrap_failure(reason), do: Bootstrap.message(reason)

  defp webhook_failure(:webhook_url_not_configured),
    do: "no public webhook URL is configured for this environment"

  defp webhook_failure(:bot_config_missing),
    do: "no Telegram bot configuration is stored; run the bootstrap first"

  defp webhook_failure({:crashed, module}), do: "unexpected failure (#{inspect(module)})"
  defp webhook_failure(reason), do: WebhookRegistration.message(reason)

  # The build environment as the `BotConfig` key ("dev", "test" or "prod").
  defp build_env, do: @app |> Application.fetch_env!(:env) |> to_string()

  # Runs `fun` with the repo and the encryption vault running, plus
  # `extra_apps`, and stops what it started. The supervision tree is never
  # started, so the endpoint and Oban stay down.
  #
  # Any crash is reduced to `{:error, {:crashed, module}}`: an exception
  # raised around secret material (a function clause error renders its
  # arguments) must not reach the caller's stack trace.
  defp with_services(extra_apps, fun) do
    Enum.each([:cloak_ecto | extra_apps], fn app ->
      {:ok, _started} = Application.ensure_all_started(app)
    end)

    vault = start_vault()

    try do
      {:ok, result, _apps} = Ecto.Migrator.with_repo(Alethea.Repo, fn _repo -> fun.() end)
      result
    rescue
      exception -> {:error, {:crashed, exception.__struct__}}
    catch
      kind, _value when kind in [:exit, :throw] -> {:error, {:crashed, kind}}
    after
      stop_vault(vault)
    end
  end

  # Under a running application (tests, a remote shell) the vault is already
  # up and is left alone.
  defp start_vault do
    case Process.whereis(Vault) do
      nil ->
        {:ok, pid} = Vault.start_link()
        {:started, pid}

      _pid ->
        :already_running
    end
  end

  defp stop_vault({:started, pid}), do: GenServer.stop(pid)
  defp stop_vault(:already_running), do: :ok

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # Database TLS needs the :ssl application started before the repo connects.
    {:ok, _started} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
