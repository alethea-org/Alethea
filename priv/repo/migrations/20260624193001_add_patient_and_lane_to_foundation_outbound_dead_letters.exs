defmodule Alethea.Repo.Migrations.AddPatientAndLaneToFoundationOutboundDeadLetters do
  @moduledoc """
  Adds `patient_id` and `lane` columns to `foundation_outbound_dead_letters`
  (Round 1 / judgment-day / WARNING-5, both judges).

  The PubSub broadcast carries both fields (the `patient_id` is the
  operator-visible identifier; the `lane` discriminates crisis clinical
  incidents from safe-lane failures), but the persisted audit row did
  not. An operator querying the table with SQL had to JOIN against
  `foundation_patients.telegram_chat_id_hash` to identify the patient
  and could not filter crisis dead-letters without parsing
  `oban_jobs.args->>'lane'` (which Oban JSON-encodes — atoms become
  strings after a round-trip).

  ## Why `on_delete: :nilify_all` (not `:delete_all`)

  Mirrors the foundation patient → legacy patient FK policy
  (`Alethea.Foundation.Accounts.Patient`). A deleted patient must not
  delete the dead-letter rows (they are audit records; the operator
  needs the historical record of "we tried to message this chat and
  it failed 5 times" even after the patient is gone).

  ## Why `lane: :string` (not `:enum`)

  The existing `messages.behavior_type` uses a check constraint with
  enum validation, but `lane` is simpler: just `"safe"` or `"crisis"`.
  A check constraint is added in this migration to enforce the two
  values at the DB level (defense in depth alongside the Ecto
  changeset `validate_inclusion`).

  ## Default `"safe"`

  Pre-existing rows (from PR #3a / TASK-3a-3) were all written with
  `lane: :safe` — the safe path was the only path that existed before
  the crisis branch landed in PR #3b. The default backfills those
  rows correctly. New crisis-path rows must pass `lane: "crisis"`
  explicitly via the worker.

  ## Backfill safety

  The migration uses `NOT VALID` + a follow-up `VALIDATE CONSTRAINT`
  to avoid holding `ACCESS EXCLUSIVE` on `foundation_outbound_dead_letters`
  during the validation pass — same pattern as WARNING-4 for the
  `messages.behavior_type` enum widening. The table is small today
  but the pattern is correct-by-default.
  """

  use Ecto.Migration

  def change do
    alter table(:foundation_outbound_dead_letters) do
      # Foundation patient UUID. Nullable — unbound-chat dead-letters
      # (the "unregistered" copy path) have no patient.
      add :patient_id,
          references(:foundation_patients,
            type: :binary_id,
            on_delete: :nilify_all,
            name: :foundation_outbound_dead_letters_patient_id_fkey
          ),
          null: true

      # Lane discriminator. The safe path pre-existed (default backfill
      # below). The crisis path is the PR #3b addition.
      add :lane, :string, null: false, default: "safe"
    end

    # Indexes for the operator query surfaces:
    # - "show me all crisis dead-letters in the last 24h"
    #   → `WHERE lane = 'crisis' AND failed_at > now() - interval '24 hours'`
    # - "show me all dead-letters for patient X"
    #   → `WHERE patient_id = $1 ORDER BY failed_at DESC`
    create index(:foundation_outbound_dead_letters, [:lane])
    create index(:foundation_outbound_dead_letters, [:patient_id])

    # DB-level validation that `lane IN ('safe', 'crisis')`. Added
    # NOT VALID first to skip the full-table scan, then validated in
    # the same migration (the table is tiny so the validation pass is
    # fast; the pattern matches the WARNING-4 migration approach).
    execute """
    ALTER TABLE foundation_outbound_dead_letters
    ADD CONSTRAINT foundation_outbound_dead_letters_lane_must_be_safe_or_crisis
    CHECK (lane IN ('safe', 'crisis')) NOT VALID
    """

    execute """
    ALTER TABLE foundation_outbound_dead_letters
    VALIDATE CONSTRAINT foundation_outbound_dead_letters_lane_must_be_safe_or_crisis
    """
  end
end
