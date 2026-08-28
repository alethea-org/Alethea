defmodule Alethea.ClinicalRecord.ClinicalNote do
  @moduledoc """
  Immutable encrypted clinical-note row (sdd/clinical-record-foundation,
  GitHub #194). Once created, a note is never updated or deleted through
  a public API — deliberately create-only:

    * Structurally: only `changeset/2` exists — no update changeset —
      and `timestamps/1` below omits `updated_at`.
    * At the database level: a `BEFORE UPDATE` trigger on the
      `clinical_notes` table (see the `create_clinical_notes` migration)
      raises on any UPDATE attempt, so `Repo.update_all`, a console
      session, or a future context cannot silently mutate a row.

  Plaintext is never cast here — `Alethea.ClinicalRecord.create_clinical_note/3`
  (PR3) encrypts under the patient's DEK before calling `changeset/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_notes" do
    field :encrypted_body, :binary
    field :encryption_version, :integer, default: 1

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Create-only changeset. There is intentionally no update changeset —
  see the moduledoc immutability note.
  """
  def changeset(clinical_note, attrs) do
    clinical_note
    |> cast(attrs, [:encrypted_body, :encryption_version, :patient_id, :professional_id])
    |> validate_required([:encrypted_body, :patient_id, :professional_id])
  end
end
