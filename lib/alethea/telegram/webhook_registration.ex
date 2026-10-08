defmodule Alethea.Telegram.WebhookRegistration do
  @moduledoc """
  Registers the Telegram webhook with `setWebhook` and verifies it with
  `getWebhookInfo`.

  ## What is sent

    * `url` — the public HTTPS URL of the webhook route (`webhook_url/1`);
    * `secret_token` — the sealed webhook secret, which Telegram echoes back
      in `X-Telegram-Bot-Api-Secret-Token` and
      `AletheaWeb.Plugs.TelegramSecretToken` compares;
    * `allowed_updates` — `["message"]`. `AletheaWeb.TelegramWebhookController`
      only matches updates that carry a `"message"` key and acknowledges and
      drops everything else, so no other update type is requested. Sending
      the list explicitly also replaces whatever a previous registration
      left behind, because Telegram keeps the earlier list when the
      parameter is omitted.

  `drop_pending_updates` is never sent: updates queued while the webhook was
  unreachable are patient messages and must be delivered after a redeploy.

  ## Flow

  1. `getWebhookInfo` reads the current state. A failure stops here.
  2. `setWebhook` is always called, even when the URL and the update list
     already match: the secret is not readable back from Telegram, so this
     call is what carries a rotated secret. Calling it with unchanged
     parameters is safe.
  3. `getWebhookInfo` verifies that Telegram now reports the same URL and
     update list.

  The result says `:already_registered` when step 1 already matched, and
  `:registered` otherwise.

  ## Failures

  No request is retried. Failures are tagged:

    * `:invalid_webhook_url` — the URL is not an HTTPS URL; nothing was sent;
    * `{:webhook_info, reason}` — `getWebhookInfo` failed before
      `setWebhook` (see `Alethea.Telegram.WebhookInfo`);
    * `{:rate_limited, retry_after}` — HTTP 429, with Telegram's
      `retry_after` seconds or `nil`;
    * `{:telegram, code, description}` — Telegram answered `ok: false` or a
      non-success status; `description` is redacted and single-line, or `nil`;
    * `{:transport, reason}` — the request did not complete;
    * `{:verification_failed, :webhook_info_unavailable | :url_mismatch |
      :allowed_updates_mismatch}` — `setWebhook` succeeded but the readback
      did not confirm it;
    * `:unexpected`.

  ## Secrets

  The Bot API URL embeds the bot token. Nothing here logs, exceptions and
  Req error structs are dropped rather than returned, and Telegram's
  `description` has the token and the secret redacted before it is returned.
  """

  alias Alethea.Telegram.WebhookInfo

  @base_url "https://api.telegram.org"
  @webhook_path "/webhooks/telegram"
  @allowed_updates ["message"]
  @max_description_length 256

  @type result :: %{
          status: :registered | :already_registered,
          webhook_url: String.t(),
          allowed_updates: [String.t()],
          pending_update_count: non_neg_integer()
        }

  @type reason ::
          :invalid_webhook_url
          | {:webhook_info, WebhookInfo.failure_reason()}
          | {:rate_limited, pos_integer() | nil}
          | {:telegram, integer(), String.t() | nil}
          | {:transport, :timeout | :dns | :tls | :connection | :unexpected}
          | {:verification_failed,
             :webhook_info_unavailable | :url_mismatch | :allowed_updates_mismatch}
          | :unexpected

  @doc "The update types requested from Telegram."
  @spec allowed_updates() :: [String.t()]
  def allowed_updates, do: @allowed_updates

  @doc "The path of the webhook route in `AletheaWeb.Router`."
  @spec webhook_path() :: String.t()
  def webhook_path, do: @webhook_path

  @doc "Builds the public webhook URL from a bare host name."
  @spec webhook_url(String.t()) :: String.t()
  def webhook_url(host) when is_binary(host), do: "https://" <> host <> @webhook_path

  @doc """
  Registers `webhook_url` for the bot and verifies the registration.
  """
  @spec register(String.t(), String.t(), String.t()) :: {:ok, result()} | {:error, reason()}
  def register(bot_token, secret_token, webhook_url)
      when is_binary(bot_token) and is_binary(secret_token) and is_binary(webhook_url) do
    with :ok <- validate_webhook_url(webhook_url),
         {:ok, before} <- current_state(bot_token),
         :ok <- set_webhook(bot_token, secret_token, webhook_url),
         {:ok, pending_update_count} <- verify(bot_token, webhook_url) do
      status = if registered?(before, webhook_url), do: :already_registered, else: :registered

      {:ok,
       %{
         status: status,
         webhook_url: webhook_url,
         allowed_updates: @allowed_updates,
         pending_update_count: pending_update_count
       }}
    end
  end

  @doc "Turns a failure tag into one line that carries no secret."
  @spec message(reason()) :: String.t()
  def message(:invalid_webhook_url), do: "the webhook URL is not an HTTPS URL"

  def message({:webhook_info, reason}) when is_atom(reason),
    do: "getWebhookInfo failed before registration (#{reason})"

  def message({:rate_limited, retry_after}) when is_integer(retry_after),
    do: "Telegram rate limited the request; retry after #{retry_after} seconds"

  def message({:rate_limited, _retry_after}), do: "Telegram rate limited the request"

  def message({:telegram, code, description}) when is_integer(code) and is_binary(description),
    do: "Telegram rejected setWebhook (#{code}): #{description}"

  def message({:telegram, code, _description}) when is_integer(code),
    do: "Telegram rejected setWebhook (#{code})"

  def message({:transport, reason}) when is_atom(reason),
    do: "setWebhook did not complete (#{reason})"

  def message({:verification_failed, reason}) when is_atom(reason),
    do: "setWebhook succeeded but verification failed (#{reason})"

  def message(_reason), do: "webhook registration failed unexpectedly"

  defp validate_webhook_url(webhook_url) do
    case URI.parse(webhook_url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _other -> {:error, :invalid_webhook_url}
    end
  end

  defp current_state(bot_token) do
    case WebhookInfo.fetch(bot_token) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, {:webhook_info, reason}}
    end
  end

  defp registered?(info, webhook_url) do
    info.webhook_url == webhook_url and Map.get(info, :allowed_updates) == @allowed_updates
  end

  defp set_webhook(bot_token, secret_token, webhook_url) do
    url = "#{@base_url}/bot#{bot_token}/setWebhook"

    body = %{
      url: webhook_url,
      secret_token: secret_token,
      allowed_updates: @allowed_updates
    }

    secrets = [bot_token, secret_token]

    try do
      case Req.post([url: url, json: body] ++ request_options()) do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} ->
          :ok

        {:ok, %Req.Response{status: 429} = response} ->
          {:error, {:rate_limited, retry_after(response)}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:telegram, error_code(body, status), description(body, secrets)}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, {:transport, WebhookInfo.classify_transport_error(reason)}}

        _other ->
          {:error, :unexpected}
      end
    rescue
      # Dropped on purpose: a Req exception can render the request URL,
      # which embeds the bot token.
      _exception -> {:error, :unexpected}
    catch
      :exit, _reason -> {:error, :unexpected}
      :throw, _value -> {:error, :unexpected}
    end
  end

  defp verify(bot_token, webhook_url) do
    case WebhookInfo.fetch(bot_token) do
      {:ok, %{webhook_url: ^webhook_url, pending_update_count: count} = info} ->
        if Map.get(info, :allowed_updates) == @allowed_updates do
          {:ok, count}
        else
          {:error, {:verification_failed, :allowed_updates_mismatch}}
        end

      {:ok, _info} ->
        {:error, {:verification_failed, :url_mismatch}}

      {:error, _reason} ->
        {:error, {:verification_failed, :webhook_info_unavailable}}
    end
  end

  # Retrying and following redirects are both off: a redirect would replay
  # the token-bearing URL and the secret to another host.
  defp request_options do
    Application.get_env(:alethea, :telegram_webhook_registration_req_options, [])
    |> Keyword.drop([:retry, :redirect])
    |> Kernel.++(retry: false, redirect: false)
  end

  defp retry_after(%Req.Response{body: %{"parameters" => %{"retry_after" => seconds}}})
       when is_integer(seconds) and seconds > 0,
       do: seconds

  defp retry_after(%Req.Response{} = response) do
    with [value | _rest] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds > 0 <- Integer.parse(value) do
      seconds
    else
      _other -> nil
    end
  end

  defp error_code(%{"error_code" => code}, _status) when is_integer(code), do: code
  defp error_code(_body, status), do: status

  defp description(%{"description" => description}, secrets) when is_binary(description) do
    secrets
    |> Enum.reduce(description, &String.replace(&2, &1, "[REDACTED]"))
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.slice(0, @max_description_length)
  end

  defp description(_body, _secrets), do: nil
end
