defmodule Alethea.ClinicalRecord.ConsultationEvidence do
  @moduledoc """
  Immutable encrypted consultation-evidence row citing a source-derived
  fact for chronological review (sdd/alethea/issue-195-clinical-review-workbench,
  GitHub #195). Provenance is table identity, not a `kind` column (design
  A1): a bad write cannot mislabel AI-authored text as source evidence.

  Cites either a `clinical_note` (this context) or a `message`
  (`Alethea.Clinical`, journaling) via `source_kind` + an untyped
  `source_id` (`:binary_id`, no FK, no `belongs_to`) — the `ClinicalRecord`
  context must not depend on `Alethea.Clinical` (design A2). The excerpt is
  copied and encrypted at citation time (design A3), so the timeline
  renders correctly even if the source row later disappears; resolution
  for display goes through the read-only `Alethea.ClinicalRecord.SourceRef`
  adapter (PR2b, not part of this schema).

  Immutable once created, mirroring `Alethea.ClinicalRecord.ClinicalNote`:

    * Structurally: only `changeset/2` exists — no update changeset —
      and `timestamps/1` below omits `updated_at`.
    * At the database level: a `BEFORE UPDATE` trigger on the
      `consultation_evidences` table (see the
      `create_consultation_evidences` migration) raises on any UPDATE
      attempt, so `Repo.update_all`, a console session, or a future
      context cannot silently mutate a row.

  Plaintext is never cast here —
  `Alethea.ClinicalRecord.add_consultation_evidence/4` (PR2a) encrypts the
  excerpt under the patient's DEK before calling `changeset/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @source_kinds ~w(clinical_note message)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:excerpt]}
  schema "consultation_evidences" do
    field :source_kind, :string
    field :source_id, :binary_id
    field :encrypted_excerpt, :binary
    field :encryption_version, :integer, default: 1
    field :occurred_at, :utc_datetime_usec
    field :excerpt, :string, virtual: true, redact: true

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Create-only changeset. There is intentionally no update changeset —
  see the moduledoc immutability note.
  """
  def changeset(consultation_evidence, attrs) do
    consultation_evidence
    |> cast(attrs, [
      :source_kind,
      :source_id,
      :encrypted_excerpt,
      :encryption_version,
      :occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_required([
      :source_kind,
      :source_id,
      :encrypted_excerpt,
      :occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_inclusion(:source_kind, @source_kinds)
  end
end
