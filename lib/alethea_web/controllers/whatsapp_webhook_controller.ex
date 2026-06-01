defmodule AletheaWeb.WhatsappWebhookController do
  use AletheaWeb, :controller

  require Logger

  alias Alethea.RateLimiter

  @doc """
  Verificación del webhook por parte de Meta (GET).
  """
  def verify(conn, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => token,
        "hub.challenge" => challenge
      }) do
    expected_token =
      Application.get_env(:alethea, :whatsapp)[:verify_token] || "alethea_verify_token"

    if token == expected_token do
      send_resp(conn, 200, challenge)
    else
      send_resp(conn, 403, "Forbidden")
    end
  end

  def verify(conn, _params) do
    send_resp(conn, 400, "Bad Request")
  end

  @doc """
  Recepción de mensajes de WhatsApp (POST).
  """
  def receive(conn, params) do
    Logger.debug("WhatsApp Webhook Received")

    # Check rate limit first
    case extract_phone_hash(params) do
      {:ok, phone_hash} ->
        case RateLimiter.check(phone_hash) do
          :ok ->
            process_validated_request(conn, params)

          {:error, :rate_limited} ->
            Logger.warning("Rate limit exceeded for phone hash")

            conn
            |> put_status(429)
            |> put_resp_content_type("application/json")
            |> send_resp(429, Jason.encode!(%{error: "Too many requests"}))
        end

      :skip_rate_limit ->
        process_validated_request(conn, params)
    end
  end

  defp process_validated_request(conn, params) do
    if valid_whatsapp_signature?(conn) do
      case parse_message(params) do
        {:ok, phone, text, message_id} ->
          %{from: phone, text: text, whatsapp_message_id: message_id}
          |> AletheaJobs.ProcessMessageWorker.new(
            unique: [period: 60, keys: [:whatsapp_message_id]]
          )
          |> Oban.insert()

          send_resp(conn, 200, "OK")

        {:error, :not_a_message} ->
          send_resp(conn, 200, "OK")

        _ ->
          send_resp(conn, 200, "OK")
      end
    else
      Logger.warning("Invalid WhatsApp Signature")
      send_resp(conn, 403, "Forbidden")
    end
  end

  # Extract phone hash from params for rate limiting
  defp extract_phone_hash(params) do
    entry = params["entry"]

    with [%{"changes" => [%{"value" => %{"messages" => [msg | _]}}]} | _] <- entry,
         phone when is_binary(phone) <- msg["from"] do
      phone_hash =
        :crypto.mac(:hmac, :sha256, Application.fetch_env!(:alethea, :phone_hash_secret), phone)
        |> Base.encode64()

      {:ok, phone_hash}
    else
      _ -> :skip_rate_limit
    end
  end

  defp valid_whatsapp_signature?(conn) do
    secret = Application.get_env(:alethea, :whatsapp)[:app_secret]
    signature_header = List.first(get_req_header(conn, "x-hub-signature-256"))
    raw_body = conn.assigns[:raw_body] || ""

    with true <- is_binary(secret) and secret != "",
         true <- is_binary(signature_header) and signature_header != "",
         true <- raw_body != "",
         computed <- :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower),
         expected <- strip_signature_prefix(signature_header) do
      secure_compare(computed, expected)
    else
      _ -> false
    end
  end

  defp strip_signature_prefix("sha256=" <> rest), do: rest
  defp strip_signature_prefix(signature), do: signature

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false

  defp parse_message(%{
         "entry" => [%{"changes" => [%{"value" => %{"messages" => [msg | _]}} | _]} | _]
       }) do
    phone = msg["from"]
    text = get_in(msg, ["text", "body"])
    message_id = msg["id"]

    if phone && text && message_id do
      {:ok, phone, text, message_id}
    else
      {:error, :incomplete_data}
    end
  end

  defp parse_message(_), do: {:error, :not_a_message}
end
