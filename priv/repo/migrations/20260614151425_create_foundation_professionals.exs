defmodule Alethea.Repo.Migrations.CreateFoundationProfessionals do
  use Ecto.Migration

  def change do
    create table(:foundation_professionals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :full_name, :string, null: false
      add :mfa_secret, :string
      add :crisis_message, :string
      add :remember_token_hash, :binary
      add :remember_token_expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:foundation_professionals, [:email])
  end
end
