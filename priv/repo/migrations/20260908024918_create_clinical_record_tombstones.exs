defmodule Alethea.Repo.Migrations.CreateClinicalRecordTombstones do
  use Ecto.Migration

  def change do
    create table(:clinical_record_tombstones, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # One of the six existing ClinicalRecord `@resource_types`.
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false

      add :patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false

      # No FK — under BR5's independent clocks the parent target_behavior
      # can itself be legally deleted while a child tombstone survives
      # (mirrors ConsultationEvidence.source_id's no-FK precedent).
      add :target_behavior_id, :binary_id

      add :deleted_at, :utc_datetime, null: false

      add :deleted_by_id,
          references(:professionals, type: :binary_id, on_delete: :restrict)

      # "sweep" | "manual"
      add :trigger, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:clinical_record_tombstones, [:resource_type, :resource_id])
    create index(:clinical_record_tombstones, [:patient_id, :deleted_at])
    create index(:clinical_record_tombstones, [:target_behavior_id])
  end
end
