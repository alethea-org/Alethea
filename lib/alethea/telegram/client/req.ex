defmodule Alethea.Telegram.Client.Req do
  @moduledoc """
  Production Req-based implementation of `Alethea.Telegram.Client`
  (C-7 outbound; PR #3a / TASK-3a-4).

  POSTs `chat_id` + `text` to
  `https://api.telegram.org/bot<token>/sendMessage` using `Req`,
  and translates the HTTP response into the callback contract
  documented on `Alethea.Telegram.Client`:

    - `200 OK` with `result.message_id` → `{:ok, message_id}`
    - `200 OK` with `ok: false`         → `{:error, {:http_error, 200, body}}`
    - `429` with `Retry-After` header   → `{:error, {:rate_limited, retry_after_seconds}}`
    - `429` without `Retry-After`       → `{:error, {:rate_limited, 1}}` (default)
    - `5xx`                              → `{:error, {:server_error, status}}`
    - Network / transport failure        → `{:error, :network}`

  The error term contract is the SAME one the `Telegram.Client.Fake`
  uses (with `queue_responses/1`), so the outbound worker's retry /
  dead-letter paths are adapter-agnostic — `Fake` for tests, `Req`
  for production, both speak the same shape.

  ## Adapter selection

  Selected at compile-time by
  `Application.get_env(:alethea, :telegram_client, Client.Fake)`.
  Set `config :alethea, :telegram_client, Alethea.Telegram.Client.Req`
  in `config/config.exs` (or `config/runtime.exs`) for production.
  The `:test` and `:dev` configs stay on `Fake`.

  ## Req options

  The adapter reads `:telegram_client_req_options` from
  `Application.get_env/3` at call-time and forwards the keyword list
  to `Req.post/2`. Tests use this to plug `Req.Test`; production
  uses it to set a receive timeout, connect timeout, or a Finch
  pool name. The default is an empty keyword list (no overrides).

  ## PHI hygiene (R-1)

  - The bot token is fetched from `Alethea.Telegram.BotToken.bot_token/0`
    (a `GenServer.call/2` to the accessor that holds the sealed
    plaintext in process state). The adapter NEVER logs the token.
  - The `text` argument is the patient's own words. The adapter
    does NOT log it at any layer; the JSON body of the HTTP request
    carries it to Telegram only.
  - The HTTP response body (which echoes the message back) is
    captured as a plain `body` term for error reporting; it is
    never logged at the `:info` level.

  ## Fail-loud on missing token

  If the `BotToken` GenServer is not running (e.g., the bot has not
  been seeded), `bot_token/0` raises (see `Alethea.Telegram.BotToken`
  moduledoc "Fail-loud boot"). The adapter does NOT swallow this —
  it propagates. Production deployments must seed a `BotConfig` row
  before the app accepts traffic.
  """

  @behaviour Alethea.Telegram.Client

  alias Alethea.Telegram.BotToken
  alias Alethea.Telegram.Client

  @base_url "https://api.telegram.org"

  @impl Client
  def send_message(chat_id, text)
      when is_integer(chat_id) and chat_id > 0 and is_binary(text) do
    url = "#{@base_url}/bot#{BotToken.bot_token()}/sendMessage"
    req_options = Application.get_env(:alethea, :telegram_client_req_options, [])

    try do
      case Req.post(url, [json: %{chat_id: chat_id, text: text}] ++ req_options) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          handle_200(body)

        {:ok, %{status: 429, headers: headers}} ->
          retry_after = parse_retry_after(headers) || 1
          {:error, {:rate_limited, retry_after}}

        {:ok, %{status: status}} when is_integer(status) and status >= 500 ->
          {:error, {:server_error, status}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, _reason} ->
          {:error, :network}
      end
    rescue
      _exception ->
        # Req does not catch transport exceptions (connection refused,
        # DNS failure, socket reset, etc.). The adapter surfaces them
        # as `{:error, :network}` so the outbound worker's retry /
        # dead-letter path treats them uniformly with 5xx responses.
        {:error, :network}
    catch
      :exit, _reason ->
        {:error, :network}

      :throw, _value ->
        {:error, :network}
    end
  end

  # ----------------------------------------------------------------
  # 200 OK handlers
  # ----------------------------------------------------------------

  defp handle_200(%{"ok" => true, "result" => %{"message_id" => id}}) when is_integer(id),
    do: {:ok, id}

  defp handle_200(%{"ok" => true}), do: {:ok, nil}
  defp handle_200(body), do: {:error, {:http_error, 200, body}}

  # ----------------------------------------------------------------
  # Retry-After header parsing
  # ----------------------------------------------------------------

  # Req 0.5 returns `headers` as a map (keys = header name, values =
  # list of strings — one entry per `Set-Cookie` line, one for
  # everything else). We accept the integer-seconds form (the only
  # one Telegram uses) and fall back to the default 1 second on
  # anything else (date format, missing header, unparseable).
  defp parse_retry_after(headers) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      [value | _] when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> nil
        end

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_retry_after(_), do: nil
end
