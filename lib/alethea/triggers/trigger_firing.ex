defmodule Alethea.Triggers.TriggerFiring do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "trigger_firings" do
    field :status, :string, default: "fired"
    field :fired_at, :utc_datetime
    field :scheduled_at, :utc_datetime

    belongs_to :trigger, Alethea.Triggers.Trigger
    belongs_to :message, Alethea.Clinical.Message

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ["fired", "skipped"]

  def changeset(firing, attrs) do
    firing
    |> cast(attrs, [:trigger_id, :message_id, :status, :fired_at, :scheduled_at])
    |> default_scheduled_at()
    |> validate_required([:trigger_id, :status, :fired_at, :scheduled_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_message_by_status()
    |> check_constraint(:message_id,
      name: :trigger_firings_status_message_check,
      message: "must be present for fired triggers and absent for skipped triggers"
    )
    |> unique_constraint([:trigger_id, :scheduled_at],
      name: :trigger_firings_trigger_id_scheduled_at_index
    )
    |> unique_constraint([:trigger_id, :message_id],
      name: :trigger_firings_trigger_id_message_id_index
    )
  end

  defp validate_message_by_status(changeset) do
    status = get_field(changeset, :status)
    message_id = get_field(changeset, :message_id)

    case status do
      "fired" ->
        if is_nil(message_id) do
          add_error(changeset, :message_id, "can't be blank")
        else
          changeset
        end

      "skipped" ->
        if not is_nil(message_id) do
          add_error(changeset, :message_id, "must be absent for skipped firings")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp default_scheduled_at(changeset) do
    case get_field(changeset, :scheduled_at) do
      nil ->
        case get_field(changeset, :fired_at) do
          nil -> changeset
          fired_at -> put_change(changeset, :scheduled_at, fired_at)
        end

      _ ->
        changeset
    end
  end
end
