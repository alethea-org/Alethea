defmodule Alethea.Repo.Migrations.CreateAiAndAuditSchema do
  use Ecto.Migration

  def change do
    # 1. AI Diagnoses (1:N relationship with messages)
    create table(:ai_diagnoses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, on_delete: :delete_all, type: :binary_id),
        null: false

      add :model_version, :string, null: false
      add :extracted_emotions, :jsonb, null: false
      add :ai_response, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ai_diagnoses, [:message_id])

    # 2. Audit Logs
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :professional_id, references(:professionals, on_delete: :nilify_all, type: :binary_id)
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :binary_id
      add :details, :jsonb, default: "{}"
      add :ip_address, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime)
    end

    create index(:audit_logs, [:professional_id])
    create index(:audit_logs, [:resource_id])
  end
end
