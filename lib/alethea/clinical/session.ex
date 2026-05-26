defmodule Alethea.Clinical.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_sessions" do
    field :started_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :status, :string, default: "open"

    belongs_to :patient, Alethea.Accounts.Patient
    has_many :messages, Alethea.Clinical.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:started_at, :closed_at, :status, :patient_id])
    |> validate_required([:started_at, :status, :patient_id])
    |> validate_inclusion(:status, ["open", "closed"])
  end
end
