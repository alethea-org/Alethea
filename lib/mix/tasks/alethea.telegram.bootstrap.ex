defmodule Mix.Tasks.Alethea.Telegram.Bootstrap do
  use Mix.Task

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Operator.TaskRuntime

  @shortdoc "Stores encrypted Telegram bot configuration"

  @moduledoc """
  Creates or updates the encrypted Telegram bot configuration for one environment.

  This task deliberately does not start the Alethea OTP application, so it works
  on a fresh database before `Alethea.Telegram.BotToken` can start. It starts only
  the Repo, encryption Vault, and their required dependencies for the duration of
  the write. Existing rows are updated atomically and no secret values are printed.

  The target environment must be one of `dev`, `test`, or `prod`. Supply secrets
  through environment variables so they do not appear in shell history:

      export TELEGRAM_BOT_TOKEN="<bot-token>"
      export TELEGRAM_WEBHOOK_SECRET="<webhook-secret>"
      export TELEGRAM_BOT_USERNAME="<bot-username>"
      mix alethea.telegram.bootstrap --env dev

  `TELEGRAM_BOT_USERNAME` may include a leading `@`; it is normalized before
  storage. On success, stdout contains only a non-secret confirmation line.
  """

  @switches [env: :string]
  @valid_envs ~w(dev test prod)
  @username_regex ~r/\A[A-Za-z0-9_]{5,32}\z/
  @secret_regex ~r/\A[A-Za-z0-9_-]{1,256}\z/

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    env = parse_env!(args)
    bot_token = required_env!("TELEGRAM_BOT_TOKEN")
    secret_token = required_env!("TELEGRAM_WEBHOOK_SECRET")
    bot_username = required_env!("TELEGRAM_BOT_USERNAME") |> String.trim_leading("@")

    unless Regex.match?(@secret_regex, secret_token) do
      Mix.raise(
        "TELEGRAM_WEBHOOK_SECRET must contain 1 to 256 letters, digits, underscores, or hyphens"
      )
    end

    unless Regex.match?(@username_regex, bot_username) do
      Mix.raise("TELEGRAM_BOT_USERNAME must contain 5 to 32 letters, digits, or underscores")
    end

    TaskRuntime.with_services(fn ->
      case BotConfig.upsert(%{
             env: env,
             bot_token: bot_token,
             secret_token: secret_token,
             bot_username: bot_username
           }) do
        {:ok, _bot_config} -> :ok
        {:error, _changeset} -> Mix.raise("Telegram bot configuration failed validation")
      end
    end)

    Mix.shell().info("TELEGRAM_BOT_CONFIGURED_ENV=#{env}")
  end

  defp parse_env!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {[env: env], [], []} when env in @valid_envs -> env
      _ -> Mix.raise("usage: mix alethea.telegram.bootstrap --env dev|test|prod")
    end
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> Mix.raise("#{name} is required")
          trimmed -> trimmed
        end

      nil ->
        Mix.raise("#{name} is required")
    end
  end
end
