defmodule Alethea.Repo.Migrations.AddSecurityFieldsToPatientsAndKeys do
  use Ecto.Migration

  def change do
    alter table(:encryption_keys) do
      add :professional_id, references(:professionals, on_delete: :nilify_all, type: :binary_id)
    end

    alter table(:patients) do
      add :urgent_intervention, :boolean, default: false, null: false
    end
  end
end
