defmodule Alethea.Repo.Migrations.AddPatientAndProfessionalTimezones do
  use Ecto.Migration

  def change do
    alter table(:professionals) do
      add :timezone, :string, default: "Etc/UTC", null: false
    end

    alter table(:patients) do
      add :timezone, :string, default: "Etc/UTC", null: false
    end
  end
end
