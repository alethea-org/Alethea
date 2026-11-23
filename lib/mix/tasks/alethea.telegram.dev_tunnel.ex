defmodule Mix.Tasks.Alethea.Telegram.DevTunnel do
  use Mix.Task

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Operator.TaskRuntime
  alias Alethea.Telegram.DevTunnel
  alias Alethea.Telegram.WebhookRegistration

  @shortdoc "Registers the Telegram webhook against the local cloudflared quick tunnel"

  @moduledoc """
  Registers the Telegram webhook for the development bot against the current
  `cloudflared` quick-tunnel URL. Available only in `:dev`.

      mix alethea.telegram.dev_tunnel [--wait SECONDS] [--metrics-url URL] [--app-url URL]

  The host name is read from the tunnel's metrics endpoint
  (`GET <metrics-url>/quicktunnel`). Defaults: `--metrics-url` is
  `TUNNEL_METRICS_URL` or `http://127.0.0.1:2000`; `--app-url` is
  `APP_HEALTH_URL` or `http://127.0.0.1:4000/health`. With `--wait`, the task
  retries until the tunnel host name and the app are reachable (and Telegram
  can resolve the new host) or the time runs out.

  The stored development `BotConfig` supplies the bot token and webhook
  secret; they are read in memory only. Output is limited to non-secret
  lines. Failures raise a single `TELEGRAM_DEV_TUNNEL_FAILED reason=...` line.

  This is the `telegram-webhook` step of `docker-compose.telegram.yml`; see
  the README section "Probar con Telegram real".
  """

  @switches [wait: :integer, metrics_url: :string, app_url: :string]
  @usage "usage: mix alethea.telegram.dev_tunnel [--wait SECONDS] [--metrics-url URL] [--app-url URL]"
  @poll_ms 2_000

  @impl Mix.Task
  def run(args), do: run(args, Mix.env(), [])

  @doc false
  def run(_args, env, _deps) when env != :dev,
    do: Mix.raise(failure("development_only"))

  def run(args, :dev, deps) do
    opts = parse!(args)
    deps = Keyword.merge(default_deps(), deps)

    Mix.Task.run("app.config")

    case safely(deps, opts) do
      {:ok, result, host} ->
        Mix.shell().info("TELEGRAM_DEV_TUNNEL_HOST=#{host}")

        Mix.shell().info(
          "TELEGRAM_WEBHOOK status=#{result.status} url=#{result.webhook_url} " <>
            "allowed_updates=#{Enum.join(result.allowed_updates, ",")} " <>
            "pending_update_count=#{result.pending_update_count}"
        )

      {:error, reason} ->
        Mix.raise(failure_message(reason))
    end
  end

  defp default_deps do
    [
      with_services: &TaskRuntime.with_services/1,
      ensure_started: &Application.ensure_all_started/1,
      lookup: &BotConfig.for_env/2,
      register: &WebhookRegistration.register/3,
      sleep: &Process.sleep/1
    ]
  end

  defp parse!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {parsed, [], []} ->
        %{
          wait: max(Keyword.get(parsed, :wait, 0), 0),
          metrics_url:
            Keyword.get(parsed, :metrics_url) || System.get_env("TUNNEL_METRICS_URL") ||
              "http://127.0.0.1:2000",
          app_url:
            Keyword.get(parsed, :app_url) || System.get_env("APP_HEALTH_URL") ||
              "http://127.0.0.1:4000/health"
        }

      _invalid ->
        Mix.raise(@usage)
    end
  end

  defp safely(deps, opts) do
    deps[:with_services].(fn ->
      with :ok <- ensure_http_client(deps[:ensure_started]),
           {:ok, bot_token, secret} <- bot_config(deps[:lookup]) do
        deadline = System.monotonic_time(:millisecond) + opts.wait * 1_000
        attempt(deps, opts, bot_token, secret, deadline)
      end
    end)
  rescue
    # Dropped on purpose: an exception can render the token-bearing request.
    _exception -> {:error, :unexpected}
  catch
    :exit, _reason -> {:error, :unexpected}
    :throw, _value -> {:error, :unexpected}
  end

  defp ensure_http_client(ensure_started) do
    case ensure_started.(:req) do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :unexpected}
    end
  end

  defp bot_config(lookup) do
    case lookup.("dev", log: false) do
      {:ok, %BotConfig{bot_token: token, secret_token: secret}}
      when is_binary(token) and is_binary(secret) ->
        {:ok, token, secret}

      _other ->
        {:error, :bot_config_missing}
    end
  end

  defp attempt(deps, opts, bot_token, secret, deadline) do
    result =
      with {:ok, host} <- DevTunnel.hostname(opts.metrics_url),
           :ok <- app_ready(opts.app_url),
           {:ok, registered} <-
             deps[:register].(bot_token, secret, WebhookRegistration.webhook_url(host)) do
        {:ok, registered, host}
      end

    case result do
      {:error, reason} ->
        if retryable?(reason) and System.monotonic_time(:millisecond) < deadline do
          deps[:sleep].(@poll_ms)
          attempt(deps, opts, bot_token, secret, deadline)
        else
          {:error, reason}
        end

      ok ->
        ok
    end
  end

  defp app_ready(url) do
    if DevTunnel.app_ready?(url), do: :ok, else: {:error, :app_unreachable}
  end

  # A fresh quick-tunnel host may not resolve for Telegram yet, so a rejected
  # or failed `setWebhook` is retried while time remains.
  defp retryable?(reason) when reason in [:tunnel_unreachable, :hostname_unavailable], do: true
  defp retryable?(:app_unreachable), do: true
  defp retryable?({:telegram, 400, _description}), do: true
  defp retryable?({:transport, _reason}), do: true
  defp retryable?({:webhook_info, reason}) when reason in [:timeout, :dns, :connection], do: true
  defp retryable?(_reason), do: false

  defp failure(reason), do: "TELEGRAM_DEV_TUNNEL_FAILED reason=#{reason}"

  defp failure_message(:tunnel_unreachable),
    do:
      failure("tunnel_unreachable") <>
        " (the cloudflared metrics endpoint did not answer; is the tunnel service running?)"

  defp failure_message(:hostname_unavailable),
    do: failure("hostname_unavailable") <> " (the tunnel has not published a host name yet)"

  defp failure_message(:app_unreachable),
    do: failure("app_unreachable") <> " (the app health check did not answer)"

  defp failure_message(:bot_config_missing),
    do:
      failure("bot_config_missing") <>
        " (no dev Telegram bot configuration is stored; run mix alethea.telegram.bootstrap --env dev)"

  defp failure_message(:unexpected), do: failure("unexpected")

  defp failure_message(reason) do
    failure("registration_failed") <> " (" <> WebhookRegistration.message(reason) <> ")"
  end
end
