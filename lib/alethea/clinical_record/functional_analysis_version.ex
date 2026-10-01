defmodule Alethea.ClinicalRecord.FunctionalAnalysisVersion do
  @moduledoc """
  Immutable, encrypted snapshot of one confirmed functional-analysis draft.
  The context copies the persisted ciphertext verbatim and encrypts the
  required change note under the same clinical-record DEK. Database-level
  UPDATE rejection preserves the snapshot while legal DELETE remains possible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect,
           except: [
             :body,
             :change_note,
             :cited_evidence_baseline_ids
           ]}
  schema "functional_analysis_versions" do
    field :encrypted_body, :binary
    field :encrypted_change_note, :binary
    field :encrypted_cited_evidence_baseline, :binary
    field :encryption_version, :integer
    field :version_number, :integer
    field :body, :string, virtual: true, redact: true
    field :change_note, :string, virtual: true, redact: true
    field :cited_evidence_baseline_ids, {:array, :string}, virtual: true, redact: true

    belongs_to :draft, Alethea.ClinicalRecord.FunctionalAnalysisDraft
    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :encrypted_body,
      :encrypted_change_note,
      :encrypted_cited_evidence_baseline,
      :encryption_version,
      :version_number,
      :draft_id,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_required([
      :encrypted_body,
      :encrypted_change_note,
      :encryption_version,
      :version_number,
      :draft_id,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_number(:version_number, greater_than: 0)
    |> validate_number(:encryption_version, greater_than: 0)
    |> unique_constraint([:target_behavior_id, :version_number])
    |> foreign_key_constraint(:draft_id, name: :functional_analysis_versions_draft_owner_fkey)
    |> foreign_key_constraint(:target_behavior_id,
      name: :functional_analysis_versions_target_owner_fkey
    )
  end
end
