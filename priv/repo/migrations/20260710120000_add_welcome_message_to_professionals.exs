defmodule Alethea.Repo.Migrations.AddWelcomeMessageToProfessionals do
  use Ecto.Migration

  def change do
    alter table(:professionals) do
      add :welcome_message, :string
    end
  end
end
