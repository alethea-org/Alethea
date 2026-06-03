defmodule Alethea.Repo.Migrations.AddWhatsappConsentLogs do
  use Ecto.Migration

  def change do
    create table(:whatsapp_consent_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :whatsapp_number, :string, null: false
      add :status, :string, null: false
      add :phone_hash, :string
      add :event_type, :string
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:whatsapp_consent_logs, [:whatsapp_number])
    create index(:whatsapp_consent_logs, [:phone_hash])
    create index(:whatsapp_consent_logs, [:status])
  end
end
