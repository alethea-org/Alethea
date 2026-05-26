defmodule Alethea.Accounts.EncryptionKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "encryption_keys" do
    field :encrypted_key, :binary
    # 'patient', 'professional'
    field :type, :string
    field :version, :integer, default: 1
    field :patient_id, :binary_id

    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:encrypted_key, :type, :version, :patient_id, :professional_id])
    |> validate_required([:encrypted_key, :type])
    |> validate_inclusion(:type, ["patient", "professional"])
  end
end
