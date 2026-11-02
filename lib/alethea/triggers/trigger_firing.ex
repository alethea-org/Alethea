defmodule Alethea.Triggers.TriggerFiring do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "trigger_firings" do
    field :status, :string, default: "fired"
    field :fired_at, :utc_datetime

    belongs_to :trigger, Alethea.Triggers.Trigger
    belongs_to :message, Alethea.Clinical.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(firing, attrs) do
    firing
    |> cast(attrs, [:trigger_id, :message_id, :status, :fired_at])
    |> validate_required([:trigger_id, :message_id, :status, :fired_at])
    |> unique_constraint(:trigger_id)
  end
end
