defmodule AletheaWeb.WhatsappWebhookController do
  use AletheaWeb, :controller

  require Logger

  @doc """
  Verificación del webhook por parte de Meta (GET).
  """
  def verify(conn, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => token,
        "hub.challenge" => challenge
      }) do
    # El verify_token debe configurarse en el dashboard de Meta y aquí.
    # Por ahora usamos uno simple o lo sacamos de config.
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
    if valid_signature?(conn) do
      Logger.debug("WhatsApp Webhook Received: #{inspect(params)}")

      # Extraer el número y el texto del mensaje
      case parse_message(params) do
        {:ok, phone, text, message_id} ->
          # Encolar el worker de Oban para procesamiento asíncrono
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

  defp valid_signature?(conn) do
    # Obtener el secreto de la app
    app_secret = Application.get_env(:alethea, :whatsapp)[:app_secret]

    # Si no hay secreto configurado (ej. dev), permitimos para no bloquear
    if is_nil(app_secret) || app_secret == "" do
      true
    else
      [signature_header] = get_req_header(conn, "x-hub-signature-256")
      # El formato es sha256={hash}
      ["sha256", signature_hash] = String.split(signature_header, "=")

      # Calcular HMAC del raw_body (guardado por CacheBodyReader)
      expected_hash =
        :crypto.mac(:hmac, :sha256, app_secret, conn.assigns.raw_body)
        |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(signature_hash, expected_hash)
    end
  rescue
    _ -> false
  end

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
