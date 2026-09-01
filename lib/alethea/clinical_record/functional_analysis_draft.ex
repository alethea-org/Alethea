defmodule Alethea.ClinicalRecord.FunctionalAnalysisDraft do
  @moduledoc """
  Encrypted, editable-in-place functional-analysis draft — exactly one row
  per target behavior (PR1b, sdd/alethea/issue-195-clinical-review-workbench,
  GitHub #195, design A7/D4).

  Single-row cardinality is enforced at the database level by
  `unique_index(:functional_analysis_drafts, [:target_behavior_id])` (see
  `create_functional_analysis_drafts` migration), mirrored here by
  `unique_constraint/2` so a duplicate insert surfaces as a normal
  changeset error rather than a raw `Ecto.ConstraintError`.
  `Alethea.ClinicalRecord.upsert_functional_analysis_draft/4` (PR2a)
  performs the actual upsert (`on_conflict: {:replace, [...]},
  conflict_target: :target_behavior_id`) so accepting a proposal updates
  the one draft in place — no version history, no second row.

  `professional_id` tracks the **last editor**, not the original author —
  it is overwritten on every upsert.

  No delete function exists for this schema (design D5's status-only
  discard applies to `AIProposal`; the draft itself is never soft- or
  hard-deleted by any planned #195 code path). Plaintext is never cast
  here — the context encrypts under the patient's DEK before calling into
  this schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:body]}
  schema "functional_analysis_drafts" do
    field :encrypted_body, :binary
    field :body, :string, virtual: true, redact: true

    belongs_to :patient, Alethea.Accounts.Patient
    # The last professional to edit/save the draft, overwritten on every
    # upsert — not necessarily the original author.
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime)
  end

  @doc "Create/upsert changeset. All fields required."
  def changeset(functional_analysis_draft, attrs) do
    functional_analysis_draft
    |> cast(attrs, [:encrypted_body, :patient_id, :professional_id, :target_behavior_id])
    |> validate_required([:encrypted_body, :patient_id, :professional_id, :target_behavior_id])
    |> unique_constraint(:target_behavior_id)
  end
end
