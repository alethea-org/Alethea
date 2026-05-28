defmodule Alethea.Repo.Migrations.AddCrisisMessageToProfessionals do
  use Ecto.Migration

  def change do
    alter table(:professionals) do
      add :crisis_message, :text
    end
  end
end
