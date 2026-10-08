defmodule Alethea.Telegram.WebhookInfo do
  @moduledoc """
  Read-only `getWebhookInfo` client.

  `fetch/2` returns only allowlisted, non-secret fields:

    * `:webhook_url` — the registered URL without userinfo, query or
      fragment, or `""` when no webhook is registered (Telegram reports an
      empty `url` in that case);
    * `:pending_update_count`;
    * `:allowed_updates` — present only when Telegram reports an explicit
      list; its absence means the default set of update types;
    * `:last_error_date` and `:last_error_message` when present.

  The request URL embeds the bot token, so failures are reduced to fixed
  tags and never carry the request, the response body or the exception.
  """

  @base_url "https://api.telegram.org"
  @max_error_message_bytes 256

  @type failure_reason ::
          :timeout
          | :dns
          | :tls
          | :connection
          | :unauthorized
          | :provider
          | :unexpected
          | :invalid_response

  @spec fetch(binary(), (keyword() -> Req.Response.t() | {:error, Exception.t()})) ::
          {:ok, map()} | {:error, failure_reason()}
  def fetch(bot_token, request \\ &Req.get/1)
      when is_binary(bot_token) and is_function(request, 1) do
    url = "#{@base_url}/bot#{bot_token}/getWebhookInfo"

    try do
      case request.([url: url] ++ request_options()) do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}}
        when is_map(result) ->
          map_result(result)

        {:ok, %Req.Response{status: status}} when status in [401, 403] ->
          {:error, :unauthorized}

        {:ok, %Req.Response{}} ->
          {:error, :provider}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, classify_transport_error(reason)}

        _other ->
          {:error, :unexpected}
      end
    rescue
      _exception -> {:error, :unexpected}
    catch
      :exit, _reason -> {:error, :unexpected}
      :throw, _value -> {:error, :unexpected}
    end
  end

  @spec format(map()) :: [binary()]
  def format(%{webhook_url: url, pending_update_count: count} = info) do
    ["WEBHOOK_URL=#{url}", "PENDING_UPDATE_COUNT=#{count}"]
    |> maybe_add("LAST_ERROR_DATE", Map.get(info, :last_error_date))
    |> maybe_add("LAST_ERROR_MESSAGE", Map.get(info, :last_error_message))
  end

  defp request_options do
    Application.get_env(:alethea, :telegram_webhook_info_req_options, [])
    |> Keyword.drop([:retry, :redirect])
    |> Kernel.++(retry: false, redirect: false)
  end

  @doc """
  Reduces a `Req.TransportError` reason to a fixed tag, so that no transport
  detail reaches a caller or a log line.
  """
  @spec classify_transport_error(term()) :: :timeout | :dns | :tls | :connection | :unexpected
  def classify_transport_error(:timeout), do: :timeout
  def classify_transport_error(:nxdomain), do: :dns
  def classify_transport_error({:tls_alert, _alert}), do: :tls

  def classify_transport_error(reason)
      when reason in [:closed, :econnrefused, :econnreset, :enetunreach, :ehostunreach, :notconn],
      do: :connection

  def classify_transport_error(_reason), do: :unexpected

  defp map_result(%{"url" => url, "pending_update_count" => count} = result)
       when is_binary(url) and is_integer(count) and count >= 0 do
    with {:ok, webhook_url} <- safe_webhook_url(url),
         {:ok, info} <-
           maybe_add_error_date(result, %{webhook_url: webhook_url, pending_update_count: count}),
         {:ok, info} <- maybe_add_error_message(result, info),
         {:ok, info} <- maybe_add_allowed_updates(result, info) do
      {:ok, info}
    end
  end

  defp map_result(_result), do: {:error, :invalid_response}

  # Telegram reports an empty URL while no webhook is registered.
  defp safe_webhook_url(""), do: {:ok, ""}

  defp safe_webhook_url(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, URI.to_string(%URI{uri | userinfo: nil, query: nil, fragment: nil})}
    else
      {:error, :invalid_response}
    end
  end

  defp maybe_add_error_date(%{"last_error_date" => timestamp}, info) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> {:ok, Map.put(info, :last_error_date, DateTime.to_iso8601(datetime))}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp maybe_add_error_date(%{"last_error_date" => _value}, _info),
    do: {:error, :invalid_response}

  defp maybe_add_error_date(_result, info), do: {:ok, info}

  defp maybe_add_error_message(%{"last_error_message" => message}, info)
       when is_binary(message) do
    {:ok, Map.put(info, :last_error_message, sanitize_error_message(message))}
  end

  defp maybe_add_error_message(%{"last_error_message" => _value}, _info),
    do: {:error, :invalid_response}

  defp maybe_add_error_message(_result, info), do: {:ok, info}

  defp maybe_add_allowed_updates(%{"allowed_updates" => updates}, info) when is_list(updates) do
    if Enum.all?(updates, &is_binary/1) do
      {:ok, Map.put(info, :allowed_updates, updates)}
    else
      {:error, :invalid_response}
    end
  end

  defp maybe_add_allowed_updates(%{"allowed_updates" => _value}, _info),
    do: {:error, :invalid_response}

  defp maybe_add_allowed_updates(_result, info), do: {:ok, info}

  defp sanitize_error_message(message) do
    message
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.slice(0, @max_error_message_bytes)
  end

  defp maybe_add(lines, _label, nil), do: lines
  defp maybe_add(lines, label, value), do: lines ++ ["#{label}=#{value}"]
end
