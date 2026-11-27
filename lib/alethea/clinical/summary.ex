defmodule Alethea.Clinical.Summary do
  @moduledoc """
  An AI-generated clinical summary (`"session"` or `"weekly"`).

  The narrative is stored only as `encrypted_summary`: ciphertext under the
  patient's DEK (`Alethea.Encryption.PatientVault`, the same scheme as
  `Alethea.Clinical.Message`). The plaintext lives in the virtual, redacted
  `summary_text` field: `Alethea.Clinical.save_summary/1` encrypts it on
  write and the `Alethea.Clinical` readers decrypt it on read (`nil` when
  the patient's key is gone). Insert only through `save_summary/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_summaries" do
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :summary_text, :string, virtual: true, redact: true
    field :encrypted_summary, :binary, redact: true
    field :status_level, :string
    field :type, :string, default: "session"

    # Structured weekly report fields — nullable for backward compatibility
    field :anxiety_score, :float
    field :social_score, :float
    field :emotional_range, :map
    field :crisis_events, :integer
    field :session_count, :integer

    belongs_to :patient, Alethea.Accounts.Patient

    timestamps(type: :utc_datetime)
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :period_start,
      :period_end,
      :summary_text,
      :status_level,
      :type,
      :patient_id,
      :anxiety_score,
      :social_score,
      :emotional_range,
      :crisis_events,
      :session_count
    ])
    |> validate_required([
      :period_start,
      :period_end,
      :summary_text,
      :status_level,
      :type,
      :patient_id
    ])
    |> validate_inclusion(:type, ["session", "weekly"])
    |> validate_number(:anxiety_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:social_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:crisis_events, greater_than_or_equal_to: 0)
    |> validate_number(:session_count, greater_than_or_equal_to: 0)
  end
end
