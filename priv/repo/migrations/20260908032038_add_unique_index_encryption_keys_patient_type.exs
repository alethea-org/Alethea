defmodule Alethea.Repo.Migrations.AddUniqueIndexEncryptionKeysPatientType do
  use Ecto.Migration

  # Race-safety for lazy `"patient_clinical_record"` key creation (D1,
  # sdd/clinical-record-retention, GitHub #197, design section "Migrations
  # (c)"). Without this, two concurrent first-writes could each insert a
  # CR-scoped key row for the same patient, and one row's ciphertext would
  # become permanently undecryptable. `Accounts.ensure_clinical_record_dek/2`
  # relies on this exact index as its `on_conflict: :nothing` target.
  #
  # `where: "patient_id IS NOT NULL"` mirrors the column's nullability
  # (some legacy `encryption_keys` rows — e.g. `"professional"` type — carry
  # no `patient_id`), so this index only constrains patient-scoped keys.
  def change do
    create unique_index(:encryption_keys, [:patient_id, :type], where: "patient_id IS NOT NULL")
  end
end
