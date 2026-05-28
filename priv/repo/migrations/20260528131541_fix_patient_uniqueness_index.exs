defmodule Alethea.Repo.Migrations.FixPatientUniquenessIndex do
  use Ecto.Migration

  def change do
    drop unique_index(:patients, [:professional_id, :whatsapp_number_hash])
    create unique_index(:patients, [:whatsapp_number_hash])
  end
end
