defmodule Alethea.Repo.Migrations.AddRiskSignalToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :risk_signal, :map
    end
  end
end
