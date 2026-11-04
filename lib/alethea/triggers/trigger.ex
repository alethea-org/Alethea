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

    field :schedule_type, :string
    field :time, :time
    field :weekdays, {:array, :integer}
    field :end_date, :date
    field :consecutive_delivery_failures, :integer, default: 0

    # #448: "active" triggers are scheduled; "reactive" ones fire when a
    # patient burst matches their patient-encrypted `condition`. `kind` is
    # set only through `reactive_changeset/2`, never cast from params.
    field :kind, :string, default: "active"
    field :condition, :binary
    field :cooldown_hours, :integer

    field :decrypted_instruction, :string, virtual: true
    field :decrypted_draft_message, :string, virtual: true
    field :decrypted_approved_text, :string, virtual: true
    field :decrypted_condition, :string, virtual: true

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
      :end_date,
      :condition,
      :cooldown_hours,
      :consecutive_delivery_failures
    ])
    |> validate_required([
      :patient_id,
      :professional_id,
      :instruction,
      :status,
      :consecutive_delivery_failures
    ])
    |> validate_inclusion(:status, [
      "active",
      "inactive",
      "fired",
      "paused_by_crisis",
      "paused_by_delivery_failures"
    ])
    |> validate_number(:consecutive_delivery_failures, greater_than_or_equal_to: 0)
    |> validate_kind_shape()
    |> check_constraint(:kind, name: :triggers_kind_check)
    |> check_constraint(:kind, name: :triggers_active_shape_check)
    |> check_constraint(:kind, name: :triggers_reactive_shape_check)
  end

  @doc """
  Changeset for a new reactive trigger (#448). Sets `kind` programmatically
  and then applies `changeset/2`, whose rules depend on the kind.
  """
  def reactive_changeset(trigger, attrs) do
    trigger
    |> change(kind: "reactive")
    |> changeset(attrs)
  end

  defp validate_kind_shape(changeset) do
    case get_field(changeset, :kind) do
      "reactive" ->
        changeset
        |> validate_required([:condition, :cooldown_hours])
        |> validate_number(:cooldown_hours, greater_than: 0)
        |> validate_absent([:scheduled_at, :schedule_type])

      _active ->
        changeset
        |> validate_required([:scheduled_at, :timezone, :schedule_type])
        |> validate_inclusion(:schedule_type, ["once", "daily", "weekly"])
        |> validate_absent([:condition])
        |> validate_schedule_fields()
    end
  end

  defp validate_absent(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_field(acc, field) do
        nil -> acc
        _present -> add_error(acc, field, "must be blank for this trigger kind")
      end
    end)
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
