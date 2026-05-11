defmodule Alethea.Accounts.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patients" do
    field :encrypted_phone, Alethea.Encryption.Binary
    field :encryption_key_id, :binary_id
    field :clinical_settings, :map, default: %{}
    field :last_interaction, :utc_datetime
    field :phone, :string, virtual: true

    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [
      :phone,
      :professional_id,
      :encryption_key_id,
      :clinical_settings,
      :last_interaction
    ])
    |> validate_required([:phone, :professional_id])
    |> put_encrypted_phone()
  end

  defp put_encrypted_phone(changeset) do
    case get_change(changeset, :phone) do
      nil -> changeset
      phone -> put_change(changeset, :encrypted_phone, phone)
    end
  end
end
