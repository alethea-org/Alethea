defmodule Alethea.Accounts.Patient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "patients" do
    field(:alias, :string)
    field(:status, :string, default: "active")
    field(:terms_accepted, :boolean, default: false)
    field(:urgent_intervention, :boolean, default: false)
    field(:encryption_version, :integer, default: 1)
    field(:session_day_of_week, :integer)
    field(:session_time, :time)

    belongs_to(:professional, Alethea.Accounts.Professional)
    belongs_to(:encryption_key, Alethea.Accounts.EncryptionKey)

    has_many(:messages, Alethea.Clinical.Message)
    has_many(:summaries, Alethea.Clinical.Summary)
    has_many(:trends, Alethea.Clinical.Trend)
    has_many(:sessions, Alethea.Clinical.Session)

    timestamps(type: :utc_datetime)
  end

  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [
      :alias,
      :status,
      :terms_accepted,
      :urgent_intervention,
      :session_day_of_week,
      :session_time,
      :professional_id,
      :encryption_key_id,
      :encryption_version
    ])
    |> validate_required([:alias, :professional_id])
    |> validate_inclusion(:status, ["active", "archived", "deleted"])
    |> validate_inclusion(:session_day_of_week, 1..7,
      message: "must be between 1 (Monday) and 7 (Sunday)"
    )
  end
end
