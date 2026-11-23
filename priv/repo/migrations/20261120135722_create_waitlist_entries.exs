defmodule Alethea.Repo.Migrations.CreateWaitlistEntries do
  use Ecto.Migration

  def change do
    create table(:waitlist_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:waitlist_entries, [:email])
  end
end
