defmodule Alethea.Repo.Migrations.AddTermsAcceptedToPatients do
  use Ecto.Migration

  def change do
    alter table(:patients) do
      add :terms_accepted, :boolean, default: false, null: false
    end
  end
end
