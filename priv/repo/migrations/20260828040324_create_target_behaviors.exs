defmodule Alethea.Repo.Migrations.CreateTargetBehaviors do
  use Ecto.Migration

  def change do
    create table(:target_behaviors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :encrypted_description, :binary, null: false
      add :encryption_version, :integer, null: false, default: 1

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Professionals with authored clinical records cannot be
      # hard-deleted — authorship must survive (design D-schema,
      # sdd/clinical-record-foundation).
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:target_behaviors, [:patient_id])
    create index(:target_behaviors, [:professional_id])
  end
end
