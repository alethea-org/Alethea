defmodule Alethea.Clinical.Summary do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_summaries" do
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :summary_text, :string
    field :status_level, :string

    belongs_to :patient, Alethea.Accounts.Patient

    timestamps(type: :utc_datetime)
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [:period_start, :period_end, :summary_text, :status_level, :patient_id])
    |> validate_required([:period_start, :period_end, :summary_text, :status_level, :patient_id])
  end
end
