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
    field :approval_revision, :integer, default: 1

    field :schedule_type, :string, default: "once"
    field :time, :time
    field :weekdays, {:array, :integer}
    field :end_date, :date

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
      :encryption_version,
      :approval_revision,
      :schedule_type,
      :time,
      :weekdays,
      :end_date
    ])
    |> validate_required([
      :patient_id,
      :professional_id,
      :instruction,
      :scheduled_at,
      :timezone,
      :status,
      :schedule_type
    ])
    |> validate_inclusion(:schedule_type, ["once", "daily", "weekly"])
    |> validate_inclusion(:status, ["active", "inactive", "fired"])
    |> validate_schedule_fields()
  end

  defp validate_schedule_fields(changeset) do
    case get_field(changeset, :schedule_type) do
      "daily" ->
        validate_required(changeset, [:time])

      "weekly" ->
        changeset
        |> validate_required([:time, :weekdays])
        |> validate_change(:weekdays, fn :weekdays, days ->
          cond do
            not is_list(days) or length(days) == 0 ->
              [weekdays: "debe incluir al menos un día de la semana"]

            Enum.any?(days, &(&1 not in 1..7)) ->
              [weekdays: "contiene días inválidos (deben ser del 1 al 7)"]

            true ->
              []
          end
        end)

      _ ->
        changeset
    end
  end
end
