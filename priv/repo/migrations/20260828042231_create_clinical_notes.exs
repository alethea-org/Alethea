defmodule Alethea.Repo.Migrations.CreateClinicalNotes do
  use Ecto.Migration

  # `clinical_notes` rows are immutable once persisted (sdd/clinical-record-foundation
  # design D1/D2). Immutability is enforced two ways:
  #   1. Structurally — no update changeset exists in
  #      `Alethea.ClinicalRecord.ClinicalNote`, and `timestamps/1` below
  #      omits `updated_at` entirely.
  #   2. At the database level — a `BEFORE UPDATE` trigger raises on any
  #      UPDATE attempt, so `Repo.update_all`, a console session, or a
  #      future context cannot silently mutate a note. DELETE remains
  #      allowed (patient FK cascade + future key-destruction erasure).
  #
  # `up`/`down` (not `change`) because the trigger/function pair needs
  # explicit reversal.
  def up do
    create table(:clinical_notes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :encrypted_body, :binary, null: false
      add :encryption_version, :integer, null: false, default: 1

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:clinical_notes, [:patient_id])
    create index(:clinical_notes, [:professional_id])

    execute """
    CREATE OR REPLACE FUNCTION clinical_notes_reject_update() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'clinical_notes rows are immutable (id=%)', OLD.id
        USING ERRCODE = 'restrict_violation';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER clinical_notes_no_update
      BEFORE UPDATE ON clinical_notes
      FOR EACH ROW EXECUTE FUNCTION clinical_notes_reject_update();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS clinical_notes_no_update ON clinical_notes"
    execute "DROP FUNCTION IF EXISTS clinical_notes_reject_update()"

    drop table(:clinical_notes)
  end
end
