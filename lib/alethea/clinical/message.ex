defmodule Alethea.Clinical.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field :direction, :string
    field :behavior_type, :string, default: "spontaneous"
    field :whatsapp_message_id, :string
    field :encrypted_content, :binary
    field :encryption_version, :integer, default: 1
    field :synced_to_graph, :boolean, default: false
    field :timestamp, :utc_datetime

    belongs_to :patient, Alethea.Accounts.Patient
    has_many :ai_diagnoses, Alethea.AI.Diagnosis

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :direction,
      :behavior_type,
      :whatsapp_message_id,
      :encrypted_content,
      :encryption_version,
      :synced_to_graph,
      :timestamp,
      :patient_id
    ])
    |> validate_required([
      :direction,
      :behavior_type,
      :encrypted_content,
      :timestamp,
      :patient_id
    ])
    |> validate_inclusion(:direction, ["inbound", "outbound"])
    |> validate_inclusion(:behavior_type, ["spontaneous", "elicited"])
    |> unique_constraint(:whatsapp_message_id)
  end
end
