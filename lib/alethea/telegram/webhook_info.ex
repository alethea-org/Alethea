defmodule Alethea.Telegram.WebhookInfo do
  @moduledoc false

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

  defp classify_transport_error(:timeout), do: :timeout
  defp classify_transport_error(:nxdomain), do: :dns
  defp classify_transport_error({:tls_alert, _alert}), do: :tls

  defp classify_transport_error(reason)
       when reason in [:closed, :econnrefused, :econnreset, :enetunreach, :ehostunreach, :notconn],
       do: :connection

  defp classify_transport_error(_reason), do: :unexpected

  defp map_result(%{"url" => url, "pending_update_count" => count} = result)
       when is_binary(url) and is_integer(count) and count >= 0 do
    with {:ok, webhook_url} <- safe_webhook_url(url),
         {:ok, info} <-
           maybe_add_error_date(result, %{webhook_url: webhook_url, pending_update_count: count}),
         {:ok, info} <- maybe_add_error_message(result, info) do
      {:ok, info}
    end
  end

  defp map_result(_result), do: {:error, :invalid_response}

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

  defp sanitize_error_message(message) do
    message
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.slice(0, @max_error_message_bytes)
  end

  defp maybe_add(lines, _label, nil), do: lines
  defp maybe_add(lines, label, value), do: lines ++ ["#{label}=#{value}"]
end
