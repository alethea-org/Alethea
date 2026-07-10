defmodule AletheaWeb.Plugs.TelegramSecretToken do
  @moduledoc """
  Webhook authentication plug for the Telegram channel (C-1).

  Validates the `X-Telegram-Bot-Api-Secret-Token` header against
  the value served by `Alethea.Telegram.BotToken.secret_token/0`
  (the encrypted-at-rest `BotConfig.secret_token_ciphertext` for
  `Mix.env()`). The check runs before the body is parsed, so a
  spoofed or replayed webhook never reaches the controller.

  ## Behaviour

    - **Matching header** (exactly one, value equals the configured
      secret): the plug forwards the conn. No halt, no response
      sent — the controller is allowed to read the body and dispatch.
    - **Missing header / wrong value / duplicate values** (the
      legitimate Telegram client always sends exactly one): the
      plug short-circuits with HTTP 401 and an empty body, then
      `halt/1`s the pipeline. **No `Logger` line is emitted for
      the rejected request** — R-1 (PHI hygiene) and the spec
      `REQ-C1-secret-token-validates-header` ("shall emit no
      `Logger` line for the rejected request"). A log line on a
      401 would also leak the request volume to a passive
      observer, which is not useful and makes the endpoint
      log-noise-loud.

  ## Constant-time comparison

  The header value is compared to the expected secret with
  `Plug.Crypto.secure_compare/2`. `==` short-circuits on the first
  byte mismatch, leaking per-byte timing information to a network
  adversary. `secure_compare/2` runs in time proportional to
  `max(byte_size(left), byte_size(right))` regardless of the
  matching prefix. Telegram's webhook spec calls this out
  explicitly; the constant-time guarantee is the security
  property the plug preserves.

  ## Why a plug, not a controller `before_action`

  The `:accepts` plug (and the Phoenix JSON body parser) must run
  AFTER the secret-token check — a successful match forwards the
  conn, a failed match short-circuits with 401. The plug is the
  smallest correct surface; a controller `before_action` would
  require the body to be parsed first, which is exactly what
  `REQ-C1-secret-token-validates-header` forbids ("shall perform
  the check before reading the request body").
  """

  import Plug.Conn

  @header "x-telegram-bot-api-secret-token"

  @doc """
  Returns the plug's compile-time options. No options today;
  declared so the plug can be referenced in a router pipeline
  (`plug AletheaWeb.Plugs.TelegramSecretToken`) without an
  options list.
  """
  def init(opts), do: opts

  @doc """
  Validates the secret-token header. See the moduledoc for the
  full behaviour matrix.
  """
  def call(conn, _opts) do
    expected = Alethea.Telegram.BotToken.secret_token()

    case get_req_header(conn, @header) do
      [token] when is_binary(token) ->
        if Plug.Crypto.secure_compare(token, expected) do
          conn
        else
          reject(conn)
        end

      _ ->
        # No header, multiple values, or non-binary value. All are
        # 401 short-circuits. We never log the request, the IP, or
        # the body — a 401 is a 401.
        reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> send_resp(401, "")
    |> halt()
  end
end
