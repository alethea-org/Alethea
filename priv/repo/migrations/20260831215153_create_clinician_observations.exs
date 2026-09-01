defmodule Alethea.Repo.Migrations.CreateClinicianObservations do
  use Ecto.Migration

  # `clinician_observations` rows are mutable (design: `changeset/2` +
  # `update_changeset/2`, body only) — no immutability trigger, unlike
  # `consultation_evidences`. No FK to any source table on purpose: this
  # schema carries no `source_kind`/`source_id` at all, the absence of
  # source columns being the structural "uncited" marker
  # (sdd/alethea/issue-195-clinical-review-workbench, PR1b).
  def change do
    create table(:clinician_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :encrypted_body, :binary, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      add :target_behavior_id,
          references(:target_behaviors, on_delete: :delete_all, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:clinician_observations, [:target_behavior_id, :occurred_at])
    create index(:clinician_observations, [:patient_id])
  end
end
