defmodule Alethea.WhatsApp.ConsentLog do
  @moduledoc """
  Persistent log of consent status for WhatsApp patients.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "whatsapp_consent_logs" do
    field(:whatsapp_number, :string)
    field(:status, :string)
    field(:phone_hash, :string)
    field(:event_type, :string)

    timestamps(type: :utc_datetime)
  end
end
