defmodule Alethea.Telegram.DevTunnel do
  @moduledoc """
  Development-only helpers for `mix alethea.telegram.dev_tunnel` (issue #484).

  A `cloudflared` quick tunnel publishes the local app on a random
  `*.trycloudflare.com` host name and reports it as JSON on its metrics
  endpoint: `GET <metrics>/quicktunnel` answers `{"hostname": "..."}`.

  `hostname/1` reads that host name; `app_ready?/1` probes the local app so
  the webhook is never registered against a tunnel with nothing behind it.
  Registration itself is `Alethea.Telegram.WebhookRegistration`; nothing
  here sends the bot token or the webhook secret anywhere.

  Failures are fixed tags and never carry the response body or the Req
  exception.
  """

  @hostname_regex ~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/

  @type failure :: :tunnel_unreachable | :hostname_unavailable

  @doc "Reads the quick-tunnel host name from the cloudflared metrics endpoint."
  @spec hostname(String.t()) :: {:ok, String.t()} | {:error, failure()}
  def hostname(metrics_url) when is_binary(metrics_url) do
    url = String.trim_trailing(metrics_url, "/") <> "/quicktunnel"

    case get(url) do
      {:ok, %Req.Response{status: 200, body: %{"hostname" => host}}}
      when is_binary(host) ->
        if Regex.match?(@hostname_regex, host),
          do: {:ok, host},
          else: {:error, :hostname_unavailable}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :hostname_unavailable}

      _other ->
        {:error, :tunnel_unreachable}
    end
  end

  @doc "True when `GET url` answers 200."
  @spec app_ready?(String.t()) :: boolean()
  def app_ready?(url) when is_binary(url) do
    match?({:ok, %Req.Response{status: 200}}, get(url))
  end

  defp get(url) do
    Req.get([url: url] ++ request_options())
  rescue
    _exception -> {:error, :unexpected}
  catch
    :exit, _reason -> {:error, :unexpected}
  end

  defp request_options do
    Application.get_env(:alethea, :telegram_dev_tunnel_req_options, [])
    |> Keyword.drop([:retry, :redirect])
    |> Kernel.++(retry: false, redirect: false, receive_timeout: 3_000)
  end
end
