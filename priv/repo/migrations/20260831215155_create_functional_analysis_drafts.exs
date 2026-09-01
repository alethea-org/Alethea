defmodule Alethea.Repo.Migrations.CreateFunctionalAnalysisDrafts do
  use Ecto.Migration

  # `functional_analysis_drafts` — exactly one row per target behavior
  # (design A7/D4). The unique index on `target_behavior_id` is the
  # enforcement point: `ClinicalRecord.upsert_functional_analysis_draft/4`
  # (PR2a) relies on it as its `conflict_target`
  # (sdd/alethea/issue-195-clinical-review-workbench, PR1b).
  def change do
    create table(:functional_analysis_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :encrypted_body, :binary, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Last editor, overwritten on every upsert.
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      add :target_behavior_id,
          references(:target_behaviors, on_delete: :delete_all, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:functional_analysis_drafts, [:target_behavior_id])
    create index(:functional_analysis_drafts, [:patient_id])
  end
end
