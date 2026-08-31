defmodule Alethea.Repo.Migrations.CreateConsultationEvidences do
  use Ecto.Migration

  # `consultation_evidences` rows are immutable once persisted
  # (sdd/alethea/issue-195-clinical-review-workbench design A3), mirroring
  # `clinical_notes` (20260828042231_create_clinical_notes.exs).
  # Immutability is enforced two ways:
  #   1. Structurally — no update changeset exists in
  #      `Alethea.ClinicalRecord.ConsultationEvidence`, and `timestamps/1`
  #      below omits `updated_at` entirely.
  #   2. At the database level — a `BEFORE UPDATE` trigger raises on any
  #      UPDATE attempt, so `Repo.update_all`, a console session, or a
  #      future context cannot silently mutate the excerpt. DELETE stays
  #      allowed (patient FK cascade + future key-destruction erasure).
  #
  # `up`/`down` (not `change`) because the trigger/function pair needs
  # explicit reversal.
  def up do
    create table(:consultation_evidences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # No FK to either `clinical_notes` or `messages` on purpose (design
      # A2): `ClinicalRecord` must not depend on `Alethea.Clinical`, and a
      # cross-context FK would let rollback of one context cascade into
      # the other. Resolution for display is read-only, at query time
      # (`Alethea.ClinicalRecord.SourceRef`, PR2b).
      add :source_kind, :string, null: false
      add :source_id, :binary_id, null: false

      add :encrypted_excerpt, :binary, null: false
      add :encryption_version, :integer, null: false, default: 1
      add :occurred_at, :utc_datetime_usec, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      add :target_behavior_id,
          references(:target_behaviors, on_delete: :delete_all, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:consultation_evidences, [:target_behavior_id, :occurred_at])
    create index(:consultation_evidences, [:patient_id])
    create index(:consultation_evidences, [:source_kind, :source_id])

    create constraint(:consultation_evidences, :source_kind_must_be_valid,
             check: "source_kind IN ('clinical_note', 'message')"
           )

    execute """
    CREATE OR REPLACE FUNCTION consultation_evidences_reject_update() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'consultation_evidences rows are immutable (id=%)', OLD.id
        USING ERRCODE = 'restrict_violation';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER consultation_evidences_no_update
      BEFORE UPDATE ON consultation_evidences
      FOR EACH ROW EXECUTE FUNCTION consultation_evidences_reject_update();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS consultation_evidences_no_update ON consultation_evidences"
    execute "DROP FUNCTION IF EXISTS consultation_evidences_reject_update()"

    drop table(:consultation_evidences)
  end
end
