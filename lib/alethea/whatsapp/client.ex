defmodule Alethea.WhatsApp.Client do
  @moduledoc """
  Cliente para interactuar con la API de WhatsApp Business de Meta.
  """
  @behaviour Alethea.WhatsApp.ClientBehaviour

  require Logger

  @impl true
  def send_message(to, body) do
    config = Application.get_env(:alethea, :whatsapp)
    token = config[:api_token]
    phone_number_id = config[:phone_number_id]
    url = "https://graph.facebook.com/v19.0/#{phone_number_id}/messages"

    payload = %{
      messaging_product: "whatsapp",
      to: to,
      type: "text",
      text: %{body: body}
    }

    Req.post(url,
      json: payload,
      auth: {:bearer, token}
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("WhatsApp API error: #{status} - #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("WhatsApp Request error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
