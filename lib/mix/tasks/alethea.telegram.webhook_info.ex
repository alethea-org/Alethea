defmodule Mix.Tasks.Alethea.Telegram.WebhookInfo do
  use Mix.Task

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Operator.TaskRuntime
  alias Alethea.Telegram.WebhookInfo

  @shortdoc "Prints safe, read-only Telegram webhook diagnostics in development"

  @moduledoc """
  Prints the current Telegram webhook URL, pending update count, and any last error
  details from Telegram. This diagnostic is available only in `:dev`.

      mix alethea.telegram.webhook_info

  The task reads the sealed development `BotConfig` only in memory and sends one
  `getWebhookInfo` GET request. It does not modify the database, Telegram webhook,
  or application configuration. Output is limited to non-secret webhook status fields.
  """

  @impl Mix.Task
  def run(args), do: run(args, Mix.env())

  def run(args, env),
    do:
      run(
        args,
        env,
        &TaskRuntime.with_services/1,
        &BotConfig.for_env/2,
        &WebhookInfo.fetch/1,
        &Application.ensure_all_started/1
      )

  def run(args, env, with_services, lookup, fetch),
    do: run(args, env, with_services, lookup, fetch, &Application.ensure_all_started/1)

  @doc false
  def run(_args, env, _with_services, _lookup, _fetch, _ensure_started) when env != :dev,
    do: Mix.raise(failure_message(:development_only))

  def run([], :dev, with_services, lookup, fetch, ensure_started)
      when is_function(with_services, 1) and is_function(lookup, 2) and is_function(fetch, 1) and
             is_function(ensure_started, 1) do
    Mix.Task.run("app.config")

    case safely_fetch_webhook_info(with_services, ensure_started, lookup, fetch) do
      {:ok, info} -> Enum.each(WebhookInfo.format(info), fn line -> Mix.shell().info(line) end)
      {:error, reason} -> Mix.raise(failure_message(reason))
    end
  end

  def run(_args, :dev, _with_services, _lookup, _fetch, _ensure_started),
    do: Mix.raise("usage: mix alethea.telegram.webhook_info")

  defp safely_fetch_webhook_info(with_services, ensure_started, lookup, fetch) do
    try do
      with_services.(fn ->
        with :ok <- ensure_http_client(ensure_started),
             {:ok, %BotConfig{bot_token: bot_token}} when is_binary(bot_token) <-
               lookup.("dev", log: false),
             {:ok, info} <- fetch.(bot_token) do
          {:ok, info}
        else
          :not_found -> {:error, :configuration_unavailable}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :configuration_unavailable}
        end
      end)
    rescue
      _exception -> {:error, :configuration_unavailable}
    catch
      :exit, _reason -> {:error, :configuration_unavailable}
      :throw, _value -> {:error, :configuration_unavailable}
    end
  end

  defp ensure_http_client(ensure_started) do
    case ensure_started.(:req) do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :configuration_unavailable}
    end
  end

  defp failure_message(:development_only),
    do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=development_only"

  defp failure_message(:configuration_unavailable),
    do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=configuration_unavailable"

  defp failure_message(:timeout), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=timeout"
  defp failure_message(:dns), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=dns"
  defp failure_message(:tls), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=tls"
  defp failure_message(:connection), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=connection"
  defp failure_message(:unauthorized), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=unauthorized"

  defp failure_message(:provider), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=provider"

  defp failure_message(:invalid_response),
    do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=invalid_response"

  defp failure_message(:unexpected), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=unexpected"
  defp failure_message(_reason), do: "TELEGRAM_WEBHOOK_INFO_FAILED reason=unexpected"
end
