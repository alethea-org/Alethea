defmodule Alethea.Repo.Migrations.RetireWhatsappPatientIdentity do
  use Ecto.Migration

  def up do
    alter table(:patients) do
      remove :whatsapp_number_hash
      remove :encrypted_whatsapp_number
    end

    alter table(:messages) do
      remove :whatsapp_message_id
    end

    drop table(:whatsapp_consent_logs)
  end

  def down do
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

    alter table(:messages) do
      add :whatsapp_message_id, :string
    end

    create unique_index(:messages, [:whatsapp_message_id],
             where: "whatsapp_message_id IS NOT NULL"
           )

    alter table(:patients) do
      add :whatsapp_number_hash, :string
      add :encrypted_whatsapp_number, :binary
    end

    create unique_index(:patients, [:whatsapp_number_hash])
  end
end
