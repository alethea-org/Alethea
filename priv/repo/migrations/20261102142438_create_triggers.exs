defmodule Alethea.Repo.Migrations.CreateTriggers do
  use Ecto.Migration

  def change do
    create table(:triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      add :instruction, :binary, null: false
      add :draft_message, :binary, null: false
      add :approved_text, :binary, null: false
      add :scheduled_at, :utc_datetime, null: false
      add :timezone, :string, null: false
      add :status, :string, null: false, default: "active"
      add :encryption_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:triggers, [:patient_id])
    create index(:triggers, [:professional_id])
    create index(:triggers, [:patient_id, :status])
    create index(:triggers, [:scheduled_at])

    alter table(:messages) do
      add :trigger_id, references(:triggers, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:messages, [:trigger_id])

    create table(:trigger_firings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trigger_id, references(:triggers, on_delete: :delete_all, type: :binary_id),
        null: false

      add :message_id, references(:messages, on_delete: :delete_all, type: :binary_id),
        null: false

      add :status, :string, null: false, default: "fired"
      add :fired_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:trigger_firings, [:trigger_id])
    create index(:trigger_firings, [:message_id])
  end
end
