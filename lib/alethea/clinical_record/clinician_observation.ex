defmodule Alethea.ClinicalRecord.ClinicianObservation do
  @moduledoc """
  Encrypted, mutable free-text observation added by the patient's
  responsible professional directly to the review timeline (PR1b, part of
  sdd/alethea/issue-195-clinical-review-workbench, GitHub #195).

  Unlike `Alethea.ClinicalRecord.ConsultationEvidence`, this schema carries
  **no source columns at all** — no `source_kind`, no `source_id` — because
  it is not derived from any note or message (spec: "it carries no
  source_kind/source_id reference"). Provenance is table identity (design
  A1): the absence of source columns is itself the "uncited" marker, and
  the review timeline renders every row of this schema labeled
  uncited/clinician-added.

  Mutable: `changeset/2` (create) and `update_changeset/2` (body only) —
  unlike the create-only `ConsultationEvidence`. Plaintext is never cast
  here — `Alethea.ClinicalRecord.add_clinician_observation/4` and
  `update_clinician_observation/4` (PR2a) encrypt under the patient's DEK
  before calling into this schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:body]}
  schema "clinician_observations" do
    field :encrypted_body, :binary
    field :occurred_at, :utc_datetime_usec
    field :body, :string, virtual: true, redact: true

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime)
  end

  @doc "Create changeset — all fields required."
  def changeset(clinician_observation, attrs) do
    clinician_observation
    |> cast(attrs, [
      :encrypted_body,
      :occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_required([
      :encrypted_body,
      :occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
  end

  @doc """
  Update changeset — casts `encrypted_body` only. Ownership fields
  (`patient_id`, `professional_id`, `target_behavior_id`) and `occurred_at`
  are structurally excluded from the cast list, so no caller can move an
  observation to a different patient/behavior via this path.
  """
  def update_changeset(clinician_observation, attrs) do
    clinician_observation
    |> cast(attrs, [:encrypted_body])
    |> validate_required([:encrypted_body])
  end
end
