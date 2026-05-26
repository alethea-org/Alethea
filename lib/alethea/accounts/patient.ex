defmodule Alethea.Accounts.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patients" do
    field :whatsapp_number_hash, :string
    field :encrypted_whatsapp_number, :binary
    field :alias, :string
    field :status, :string, default: "active"
    field :terms_accepted, :boolean, default: false
    field :encryption_version, :integer, default: 1

    # Virtual field for the raw number during input
    field :whatsapp_number, :string, virtual: true
    field :session_day_of_week, :integer
    field :session_time, :time

    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :encryption_key, Alethea.Accounts.EncryptionKey

    has_many :messages, Alethea.Clinical.Message
    has_many :summaries, Alethea.Clinical.Summary
    has_many :trends, Alethea.Clinical.Trend
    has_many :sessions, Alethea.Clinical.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [
      :whatsapp_number,
      :whatsapp_number_hash,
      :encrypted_whatsapp_number,
      :alias,
      :status,
      :terms_accepted,
      :professional_id,
      :encryption_key_id,
      :encryption_version
    ])
    |> validate_required([:alias, :professional_id])
    |> validate_inclusion(:status, ["active", "archived", "deleted"])
    |> unique_constraint(:whatsapp_number_hash, name: :patients_professional_id_whatsapp_number_hash_index)

    # Logic for hashing and encrypting the number would go here or in a context
  end
end
