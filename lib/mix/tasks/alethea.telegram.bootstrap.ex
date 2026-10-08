defmodule Mix.Tasks.Alethea.Telegram.Bootstrap do
  use Mix.Task

  alias Alethea.Operator.TaskRuntime
  alias Alethea.Telegram.Bootstrap

  @shortdoc "Stores encrypted Telegram bot configuration"

  @moduledoc """
  Creates or updates the encrypted Telegram bot configuration for one environment.

  This task deliberately does not start the Alethea OTP application, so it works
  on a fresh database before `Alethea.Telegram.BotToken` can start. It starts only
  the Repo, encryption Vault, and their required dependencies for the duration of
  the write. Existing rows are updated atomically and no secret values are printed.

  The validation and the write live in `Alethea.Telegram.Bootstrap`, which a
  release reaches through `bin/telegram_bootstrap` (Mix tasks do not exist in a
  release).

  The target environment must be one of `dev`, `test`, or `prod`. Supply secrets
  through environment variables so they do not appear in shell history:

      export TELEGRAM_BOT_TOKEN="<bot-token>"
      export TELEGRAM_WEBHOOK_SECRET="<webhook-secret>"
      export TELEGRAM_BOT_USERNAME="<bot-username>"
      mix alethea.telegram.bootstrap --env dev

  `TELEGRAM_BOT_USERNAME` may include a leading `@`; it is normalized before
  storage. On success, stdout contains only non-secret confirmation lines: the
  environment and whether the row was `created`, `updated` or left `unchanged`.
  """

  @switches [env: :string]
  @valid_envs ~w(dev test prod)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    env = parse_env!(args)

    # Validation runs before any service starts, so a malformed variable
    # never opens a database connection.
    attrs =
      case Bootstrap.validate(System.get_env()) do
        {:ok, attrs} -> attrs
        {:error, reason} -> Mix.raise(Bootstrap.message(reason))
      end

    case TaskRuntime.with_services(fn -> Bootstrap.write(env, attrs) end) do
      {:ok, %{status: status}} ->
        Mix.shell().info("TELEGRAM_BOT_CONFIGURED_ENV=#{env}")
        Mix.shell().info("TELEGRAM_BOT_CONFIG_STATUS=#{status}")

      {:error, reason} ->
        Mix.raise(Bootstrap.message(reason))
    end
  end

  defp parse_env!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {[env: env], [], []} when env in @valid_envs -> env
      _ -> Mix.raise("usage: mix alethea.telegram.bootstrap --env dev|test|prod")
    end
  end
end
