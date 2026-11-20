defmodule AletheaWeb.Plugs.PaddleSignature do
  @moduledoc """
  Authenticates Paddle Billing webhooks.

  Verifies the `Paddle-Signature` header against the raw request body
  (cached by `AletheaWeb.Plugs.CacheBodyReader`) with the configured
  webhook secret, via `Alethea.Billing.Signature`. On any failure it
  responds 401 with an empty body and halts, adding no log line of its
  own (the standard request log still records the request), so a forged
  notification never reaches the controller.
  """

  import Plug.Conn

  alias Alethea.Billing
  alias Alethea.Billing.Signature

  @header "paddle-signature"

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, @header),
         true <- Signature.valid?(header, conn.assigns[:raw_body], Billing.webhook_secret()) do
      conn
    else
      _ ->
        conn
        |> send_resp(401, "")
        |> halt()
    end
  end
end
