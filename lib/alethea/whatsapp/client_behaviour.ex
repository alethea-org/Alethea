defmodule Alethea.WhatsApp.ClientBehaviour do
  @callback send_message(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
end
