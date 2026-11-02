defmodule Alethea.Triggers.Trigger do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "triggers" do
    field :instruction, :binary
    field :draft_message, :binary
    field :approved_text, :binary
    field :scheduled_at, :utc_datetime
    field :timezone, :string
    field :status, :string, default: "active"
    field :encryption_version, :integer, default: 1

    field :decrypted_instruction, :string, virtual: true
    field :decrypted_draft_message, :string, virtual: true
    field :decrypted_approved_text, :string, virtual: true

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    has_many :firings, Alethea.Triggers.TriggerFiring

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :patient_id,
      :professional_id,
      :instruction,
      :draft_message,
      :approved_text,
      :scheduled_at,
      :timezone,
      :status,
      :encryption_version
    ])
    |> validate_required([
      :patient_id,
      :professional_id,
      :instruction,
      :draft_message,
      :approved_text,
      :scheduled_at,
      :timezone,
      :status
    ])
    |> validate_inclusion(:status, ["active", "fired"])
  end
end
