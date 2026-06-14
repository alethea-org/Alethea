defmodule Alethea.Repo.Migrations.CreateFoundationPatients do
  use Ecto.Migration

  def change do
    create table(:foundation_patients, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :professional_id,
          references(:foundation_professionals,
            on_delete: :delete_all,
            type: :binary_id
          ),
          null: false

      add :alias, :string, null: false
      add :status, :string, default: "active", null: false
      add :telegram_chat_id, :string

      add :profile_name, :string
      add :profile_birth_date, :date
      add :profile_gender, :string
      add :profile_language, :string
      add :profile_email, :string

      add :emergency_contact_name, :string
      add :emergency_contact_relationship, :string
      add :emergency_contact_phone, :string

      timestamps(type: :utc_datetime)
    end

    create index(:foundation_patients, [:professional_id])
    create index(:foundation_patients, [:status])
  end
end
