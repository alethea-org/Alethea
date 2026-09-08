defmodule Alethea.Repo.Migrations.AddEncryptionVersionToClinicalRecordTables do
  use Ecto.Migration

  # `target_behaviors`, `clinical_notes`, `consultation_evidences`, and
  # `clinical_record_rag_chunks` already carry `encryption_version` (from
  # earlier PRs). These are the 3 of 6 `ClinicalRecord` tables still
  # missing it — required for AD1's dual-read-by-`encryption_version` to be
  # uniform across every table the keyring seam touches (design section
  # "Migrations (d)", sdd/clinical-record-retention, GitHub #197).
  def change do
    alter table(:clinician_observations) do
      add :encryption_version, :integer, null: false, default: 1
    end

    alter table(:ai_proposals) do
      add :encryption_version, :integer, null: false, default: 1
    end

    alter table(:functional_analysis_drafts) do
      add :encryption_version, :integer, null: false, default: 1
    end
  end
end
