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
    expected_token = Application.get_env(:alethea, :whatsapp)[:verify_token] || "alethea_verify_token"

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
    Logger.debug("WhatsApp Webhook Received: #{inspect(params)}")

    # Extraer el número y el texto del mensaje
    # El payload de Meta es anidado: entry -> changes -> value -> messages
    case parse_message(params) do
      {:ok, phone, text, message_id} ->
        # Encolar el worker de Oban para procesamiento asíncrono
        %{from: phone, text: text, whatsapp_message_id: message_id}
        |> AletheaJobs.ProcessMessageWorker.new(unique: [fields: [:whatsapp_message_id]])
        |> Oban.insert()

        send_resp(conn, 200, "OK")

      {:error, :not_a_message} ->
        # Meta envía notificaciones de lectura y otros eventos que ignoramos por ahora
        send_resp(conn, 200, "OK")

      _ ->
        send_resp(conn, 200, "OK")
    end
  end

  defp parse_message(%{"entry" => [%{"changes" => [%{"value" => %{"messages" => [msg | _]}} | _]} | _]}) do
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
