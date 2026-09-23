defmodule Alethea.Repo.Migrations.CreateDismissedEvidenceSuggestions do
  use Ecto.Migration

  def change do
    create table(:dismissed_evidence_suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Professionals with authored clinical decisions cannot be hard-deleted,
      # mirroring consultation_evidences, target_behaviors, etc.
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      # Target behavior is part of the composite FK with patient_id below (GitHub #289).
      add :target_behavior_id, :binary_id, null: false

      # Identifier of the dismissed RAG chunk and/or source resource.
      add :chunk_id, :binary_id
      add :resource_id, :binary_id
      add :resource_type, :string

      # Timestamp when the professional performed the dismissal.
      add :dismissed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Composite FK ensuring target_behavior belongs to the same patient
    # and cascading deletion when the target_behavior is removed (GitHub #289, #315).
    execute(
      """
      ALTER TABLE dismissed_evidence_suggestions
        ADD CONSTRAINT dismissed_evidence_suggestions_target_behavior_patient_fkey
        FOREIGN KEY (target_behavior_id, patient_id)
        REFERENCES target_behaviors (id, patient_id)
        ON DELETE CASCADE
      """,
      """
      ALTER TABLE dismissed_evidence_suggestions
        DROP CONSTRAINT IF EXISTS dismissed_evidence_suggestions_target_behavior_patient_fkey
      """
    )

    create index(:dismissed_evidence_suggestions, [:patient_id])
    create index(:dismissed_evidence_suggestions, [:target_behavior_id])

    # Ensure idempotency per target_behavior for chunk and resource dismissals
    create unique_index(
             :dismissed_evidence_suggestions,
             [:target_behavior_id, :chunk_id],
             name: :dismissed_evidence_suggestions_target_behavior_chunk_index,
             where: "chunk_id IS NOT NULL"
           )

    create unique_index(
             :dismissed_evidence_suggestions,
             [:target_behavior_id, :resource_id],
             name: :dismissed_evidence_suggestions_target_behavior_resource_index,
             where: "resource_id IS NOT NULL"
           )
  end
end
