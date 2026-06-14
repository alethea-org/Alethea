defmodule Alethea.Repo.Migrations.CreateFoundationAdmins do
  use Ecto.Migration

  def change do
    create table(:foundation_admins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:foundation_admins, [:email])
  end
end
