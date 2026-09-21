defmodule Alethea.Repo.Migrations.CompositeFkTargetBehaviorPatient do
  use Ecto.Migration

  # GitHub #289 — make a mismatched `(target_behavior_id, patient_id)` pair
  # impossible at the database level.
  #
  # Every child of `target_behaviors` carries `patient_id` and
  # `target_behavior_id` as two independent single-column FKs, so Postgres
  # accepted a row pairing patient A with patient B's target behavior. Each
  # single-column `target_behavior_id` FK is replaced by a composite FK
  # `(target_behavior_id, patient_id) -> target_behaviors (id, patient_id)`.
  #
  # `ON DELETE` behavior is preserved per table:
  #
  #   * `CASCADE` on the four tables that cascade today.
  #   * `SET NULL (target_behavior_id)` on `clinical_record_rag_chunks`. Its
  #     `target_behavior_id` is a nullable facet and `patient_id` is
  #     `NOT NULL`, so a plain composite `SET NULL` would try to null
  #     `patient_id` and fail. The column-list form (Postgres 15+; CI, the
  #     compose files and prod all run 16) nulls only the facet. With the
  #     default `MATCH SIMPLE`, a chunk whose `target_behavior_id` is NULL is
  #     not checked against the parent.
  #
  # `clinical_record_tombstones` is deliberately excluded: it carries no FK,
  # because the target behavior can be legally deleted while its tombstone
  # survives (see `Alethea.ClinicalRecord.Tombstone`).
  #
  # Plain `ADD CONSTRAINT` (not `NOT VALID` + `VALIDATE`): the project is
  # pre-launch with no real user data, so validation is instantaneous.

  @cascading_tables ~w(
    consultation_evidences
    clinician_observations
    ai_proposals
    functional_analysis_drafts
  )

  @rag_chunks "clinical_record_rag_chunks"

  def up do
    # Postgres requires a unique index on the referenced columns. It is
    # trivially satisfied because `id` is already the primary key.
    create unique_index(:target_behaviors, [:id, :patient_id])

    for table <- @cascading_tables do
      drop_single_column_fk(table)
      add_composite_fk(table, "ON DELETE CASCADE")
    end

    drop_single_column_fk(@rag_chunks)
    add_composite_fk(@rag_chunks, "ON DELETE SET NULL (target_behavior_id)")
  end

  def down do
    for table <- @cascading_tables do
      drop_composite_fk(table)
      add_single_column_fk(table, "CASCADE")
    end

    drop_composite_fk(@rag_chunks)
    add_single_column_fk(@rag_chunks, "SET NULL")

    drop unique_index(:target_behaviors, [:id, :patient_id])
  end

  defp drop_single_column_fk(table) do
    execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_target_behavior_id_fkey")
  end

  defp add_composite_fk(table, on_delete) do
    execute("""
    ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_target_behavior_patient_fkey
      FOREIGN KEY (target_behavior_id, patient_id)
      REFERENCES target_behaviors (id, patient_id)
      #{on_delete}
    """)
  end

  defp drop_composite_fk(table) do
    execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_target_behavior_patient_fkey")
  end

  defp add_single_column_fk(table, on_delete) do
    execute("""
    ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_target_behavior_id_fkey
      FOREIGN KEY (target_behavior_id)
      REFERENCES target_behaviors (id)
      ON DELETE #{on_delete}
    """)
  end
end
