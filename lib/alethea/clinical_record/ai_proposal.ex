defmodule Alethea.ClinicalRecord.AIProposal do
  @moduledoc """
  Encrypted, clinician-triggered AI-generated functional-analysis
  proposal (PR1b, sdd/alethea/issue-195-clinical-review-workbench, GitHub
  #195). Provisional-only material (spec: "MUST NOT diagnose, recommend
  treatment, resolve conflicts, confirm evidence, or write a clinical
  note"): every row starts `status: "pending"` and requires an explicit
  clinician action (accept/edit/discard) to move out of it.

  Two encrypted columns, mirroring design A6/D3:

    * `encrypted_original_text` — the model's verbatim output at
      generation time. **Write-once**: `update_changeset/2` never casts
      it, so no edit (or malicious update attrs) can overwrite the
      original AI text.
    * `encrypted_text` — the currently-displayed text; starts identical
      to `encrypted_original_text`, diverges only via `update_changeset/2`
      when the clinician edits (`status` becomes `"edited"`).

  `status` is forced to `"pending"` on insert via `put_change/3` in
  `changeset/2` — never `cast`, so no attrs map (however constructed) can
  make a freshly-inserted proposal anything other than `"pending"` (design
  A6). Only `update_changeset/2`, called from the context's
  `accept_ai_proposal/3`, `edit_ai_proposal/4`, and `discard_ai_proposal/3`
  (PR2a), can move it forward. Discard is a soft `status` transition
  (design D5) — no delete function exists for this schema.

  PHI hygiene mirrors `Alethea.AI.Diagnosis`: `redact: true` on the virtual
  plaintext fields covers `%Ecto.Changeset{}` inspect, `@derive` covers
  bare struct inspect. Plaintext is never cast here —
  `Alethea.ClinicalRecord.request_ai_proposals/3`'s Oban worker (PR4)
  encrypts under the patient's DEK before calling into this schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending edited accepted discarded)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:original_text, :text]}
  schema "ai_proposals" do
    field :encrypted_original_text, :binary
    field :encrypted_text, :binary
    field :status, :string
    field :model_version, :string
    field :occurred_at, :utc_datetime_usec
    field :original_text, :string, virtual: true, redact: true
    field :text, :string, virtual: true, redact: true

    belongs_to :patient, Alethea.Accounts.Patient
    # The requester of the AI generation — not necessarily the professional
    # who later accepts/edits/discards the resulting proposal.
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime)
  end

  @doc """
  Create changeset. `status` is never cast from `attrs` — it is always
  forced to `"pending"` via `put_change/3` after casting everything else,
  so no caller can insert a proposal in any other status (design A6).
  """
  def changeset(ai_proposal, attrs) do
    ai_proposal
    |> cast(attrs, [
      :encrypted_original_text,
      :encrypted_text,
      :model_version,
      :occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_required([
      :encrypted_original_text,
      :encrypted_text,
      :model_version,
      :occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> put_change(:status, "pending")
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Update changeset — casts `encrypted_text` and `status` only.
  `encrypted_original_text` is structurally excluded from the cast list
  (design D3 — write-once): no attrs map, however constructed, can
  overwrite the model's original output through this path.
  """
  def update_changeset(ai_proposal, attrs) do
    ai_proposal
    |> cast(attrs, [:encrypted_text, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
