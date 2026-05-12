defmodule Alethea.Repo.Migrations.CreateClinicalSchema do
  use Ecto.Migration

  def change do
    # 1. Messages Table
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # inbound, outbound
      add :direction, :string, null: false
      add :encrypted_content, :binary, null: false
      add :encryption_version, :integer, default: 1
      add :synced_to_graph, :boolean, default: false, null: false
      add :timestamp, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:patient_id])
    create index(:messages, [:timestamp])

    # 2. Clinical Summaries
    create table(:clinical_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      add :period_start, :utc_datetime, null: false
      add :period_end, :utc_datetime, null: false
      add :summary_text, :text, null: false
      # Estable, Alerta, Intervención Requerida
      add :status_level, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:clinical_summaries, [:patient_id])

    # 3. Clinical Trends
    create table(:clinical_trends, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Ansiedad, Sueño, etc.
      add :indicator_name, :string, null: false
      add :score, :float, null: false
      add :delta, :float, null: false
      add :recorded_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:clinical_trends, [:patient_id, :indicator_name])
  end
end
