defmodule Alethea.Clinical.RunningSummary.Snapshot do
  @moduledoc """
  One protected factual running summary per patient (#394).

  `encrypted_summary` is ciphertext under the journaling `"patient"` DEK
  (never the clinical-record DEK). The plaintext lives only in the virtual,
  redacted `summary` field and is hidden from `inspect/1`.

  There is deliberately no changeset: `patient_id` and `professional_id` are
  set programmatically and every write goes through `insert_all`/`update_all`
  in `Alethea.Clinical.RunningSummary`, with the composite tenant FK as the
  database-level guard.
  """
  use Ecto.Schema

  @derive {Inspect, except: [:summary, :encrypted_summary]}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "running_summaries" do
    field :encrypted_summary, :binary
    field :encryption_version, :integer, default: 1
    field :covered_inbound_count, :integer
    field :summary, :string, virtual: true, redact: true

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :covered_through_message, Alethea.Clinical.Message

    timestamps(type: :utc_datetime)
  end
end
