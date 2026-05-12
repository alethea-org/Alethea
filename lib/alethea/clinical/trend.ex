defmodule Alethea.Clinical.Trend do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_trends" do
    field :indicator_name, :string
    field :score, :float
    field :delta, :float
    field :recorded_at, :utc_datetime

    belongs_to :patient, Alethea.Accounts.Patient

    timestamps(type: :utc_datetime)
  end

  def changeset(trend, attrs) do
    trend
    |> cast(attrs, [:indicator_name, :score, :delta, :recorded_at, :patient_id])
    |> validate_required([:indicator_name, :score, :delta, :recorded_at, :patient_id])
  end
end
