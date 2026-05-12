defmodule Alethea.Repo.Migrations.UpdateAccountsAndKeys do
  use Ecto.Migration

  def change do
    # 1. Update Professionals
    alter table(:professionals) do
      add :full_name, :string
    end

    # 2. Create Encryption Keys (Required for Envelope Encryption)
    create table(:encryption_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Self-referencing FK added after patients update if needed, but here it can stay as binary_id
      add :patient_id, :binary_id
      add :encrypted_key, :binary, null: false
      # 'patient' or 'professional'
      add :type, :string, null: false
      add :version, :integer, default: 1

      timestamps(type: :utc_datetime)
    end

    # 3. Update Patients with Privacy and Security requirements
    alter table(:patients) do
      remove :encrypted_phone
      # Moved or restructured if needed, but per DER it's not explicitly in the main list
      remove :clinical_settings

      add :whatsapp_number_hash, :string, null: false
      add :encrypted_whatsapp_number, :binary, null: false
      add :alias, :string, null: false
      add :status, :string, default: "active", null: false
      add :encryption_version, :integer, default: 1

      # Link to the encryption key
      modify :encryption_key_id,
             references(:encryption_keys, on_delete: :nilify_all, type: :binary_id)
    end

    create unique_index(:patients, [:professional_id, :whatsapp_number_hash])
  end
end
