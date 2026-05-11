defmodule Alethea.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:professionals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :mfa_secret, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:professionals, [:email])

    create table(:patients, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :professional_id, references(:professionals, on_delete: :delete_all, type: :binary_id),
        null: false

      add :encrypted_phone, :binary, null: false
      add :encryption_key_id, :binary_id
      add :clinical_settings, :jsonb, default: "{}", null: false
      add :last_interaction, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:patients, [:professional_id])
  end
end
