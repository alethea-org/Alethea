defmodule Alethea.Repo.Migrations.CreateFunctionalAnalysisVersions do
  use Ecto.Migration

  def up do
    create unique_index(:functional_analysis_drafts, [:id, :patient_id, :target_behavior_id],
             name: :functional_analysis_drafts_version_owner_index
           )

    create table(:functional_analysis_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :encrypted_body, :binary, null: false
      add :encrypted_change_note, :binary, null: false
      add :encryption_version, :integer, null: false
      add :version_number, :integer, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      add :professional_id,
          references(:professionals, on_delete: :restrict, type: :binary_id),
          null: false

      add :draft_id, :binary_id, null: false
      add :target_behavior_id, :binary_id, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:functional_analysis_versions, [:target_behavior_id, :version_number])

    create index(:functional_analysis_versions, [
             :patient_id,
             :target_behavior_id,
             :version_number
           ])

    create index(:functional_analysis_versions, [:draft_id])

    execute """
    ALTER TABLE functional_analysis_versions
      ADD CONSTRAINT functional_analysis_versions_draft_owner_fkey
      FOREIGN KEY (draft_id, patient_id, target_behavior_id)
      REFERENCES functional_analysis_drafts (id, patient_id, target_behavior_id)
      ON DELETE CASCADE
    """

    execute """
    ALTER TABLE functional_analysis_versions
      ADD CONSTRAINT functional_analysis_versions_target_owner_fkey
      FOREIGN KEY (target_behavior_id, patient_id)
      REFERENCES target_behaviors (id, patient_id)
      ON DELETE CASCADE
    """

    execute """
    CREATE OR REPLACE FUNCTION functional_analysis_versions_reject_update() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'functional_analysis_versions rows are immutable (id=%)', OLD.id
        USING ERRCODE = 'restrict_violation';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER functional_analysis_versions_no_update
      BEFORE UPDATE ON functional_analysis_versions
      FOR EACH ROW EXECUTE FUNCTION functional_analysis_versions_reject_update();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS functional_analysis_versions_no_update ON functional_analysis_versions"
    execute "DROP FUNCTION IF EXISTS functional_analysis_versions_reject_update()"

    execute "ALTER TABLE functional_analysis_versions DROP CONSTRAINT IF EXISTS functional_analysis_versions_draft_owner_fkey"

    execute "ALTER TABLE functional_analysis_versions DROP CONSTRAINT IF EXISTS functional_analysis_versions_target_owner_fkey"

    drop table(:functional_analysis_versions)

    drop index(:functional_analysis_drafts, [],
           name: :functional_analysis_drafts_version_owner_index
         )
  end
end
