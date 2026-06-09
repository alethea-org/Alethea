defmodule Alethea.Repo.Migrations.AddRememberTokenToProfessionals do
  use Ecto.Migration

  def change do
    alter table(:professionals) do
      add :remember_token_hash, :binary
      add :remember_token_expires_at, :utc_datetime
    end

    create unique_index(:professionals, [:remember_token_hash],
             where: "remember_token_hash IS NOT NULL"
           )
  end
end
