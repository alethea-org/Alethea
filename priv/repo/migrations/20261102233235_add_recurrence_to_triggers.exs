defmodule Alethea.Repo.Migrations.AddRecurrenceToTriggers do
  use Ecto.Migration

  def up do
    alter table(:triggers) do
      add :schedule_type, :string, null: false, default: "once"
      add :time, :time
      add :weekdays, {:array, :integer}
      add :end_date, :date
    end

    drop_if_exists unique_index(:trigger_firings, [:trigger_id])

    alter table(:trigger_firings) do
      add :scheduled_at, :utc_datetime
    end

    execute "UPDATE trigger_firings SET scheduled_at = fired_at WHERE scheduled_at IS NULL", ""

    alter table(:trigger_firings) do
      modify :scheduled_at, :utc_datetime, null: false
    end

    create unique_index(:trigger_firings, [:trigger_id, :scheduled_at])
    create index(:trigger_firings, [:trigger_id])
  end

  def down do
    drop_if_exists unique_index(:trigger_firings, [:trigger_id, :scheduled_at])
    drop_if_exists index(:trigger_firings, [:trigger_id])
    create unique_index(:trigger_firings, [:trigger_id])

    alter table(:trigger_firings) do
      remove :scheduled_at
    end

    alter table(:triggers) do
      remove :schedule_type
      remove :time
      remove :weekdays
      remove :end_date
    end
  end
end
