defmodule Alethea.Repo.Migrations.AddLegacyPatientIdToFoundationPatients do
  @moduledoc """
  Adds the `legacy_patient_id` foreign key to `foundation_patients`,
  bridging the foundation v2 identity row to the legacy
  `patients` row that backs the clinical message pipeline.

  ## Why this column exists (REQ-C3-worker-resolves-patient + C-5)

  The `TelegramMessageWorker` (PR #3a) resolves the inbound chat via
  `Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1`, which
  returns a `foundation_patients` row. The downstream
  `Clinical.save_message/7` (and the new
  `Clinical.save_telegram_message/7`) writes a `messages` row whose
  `patient_id` references the legacy `patients.id`. The two schemas
  live in parallel namespaces per `bootstrap-alethea-v2`; this FK is
  the single explicit bridge.

  ## How it is populated

  - **PR #3a (this PR):** `nil`. The TelegramMessageWorker test
    fixtures set it manually. No production data exists yet because
    the Telegram onboarding worker (PR #4) creates both rows in
    lockstep and populates the column.
  - **PR #4 (onboarding):** the `TelegramOnboardingWorker` creates
    the foundation Patient + the legacy Patient in one transaction
    and sets `legacy_patient_id` on the foundation row.

  ## Nullable + no backfill

  Existing `foundation_patients` rows pre-date the Telegram channel
  and have no legacy counterpart. The column is `null: true` and no
  backfill is attempted: a foundation row without a legacy bridge
  represents a patient who has not been onboarded to the clinical
  pipeline (e.g., a row created by the foundation admin tools
  before this PR).

  ## Boundary with legacy

  The `patients` table uses `on_delete: :delete_all` from the
  `messages` table; the inverse — "what happens to the foundation
  row when the legacy row is deleted" — is intentionally
  `on_delete: :nilify_all`. Deleting a legacy patient (admin
  tooling, GDPR right-to-erasure) must not cascade-delete the
  foundation identity row. The clinical record is purged; the
  identity record remains so future re-onboarding can re-link.
  """

  use Ecto.Migration

  def change do
    alter table(:foundation_patients) do
      add :legacy_patient_id,
          references(:patients, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:foundation_patients, [:legacy_patient_id])
  end
end
