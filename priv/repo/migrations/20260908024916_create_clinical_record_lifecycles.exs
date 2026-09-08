defmodule Alethea.Repo.Migrations.CreateClinicalRecordLifecycles do
  use Ecto.Migration

  def change do
    create table(:clinical_record_lifecycles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false

      # NULL = no active hold.
      add :legal_hold_at, :utc_datetime

      add :legal_hold_by_id,
          references(:professionals, type: :binary_id, on_delete: :restrict)

      add :legal_hold_released_at, :utc_datetime

      # NULL = global baseline (BR7); non-NULL is a per-patient stricter minimum.
      add :retention_minimum_days, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:clinical_record_lifecycles, [:patient_id])
    create index(:clinical_record_lifecycles, [:legal_hold_at])
  end
end
