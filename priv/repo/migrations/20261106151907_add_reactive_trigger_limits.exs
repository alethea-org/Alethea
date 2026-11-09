defmodule Alethea.Repo.Migrations.AddReactiveTriggerLimits do
  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add :fire_once, :boolean, null: false, default: false
      add :cooldown_reset_at, :utc_datetime
    end
  end
end
