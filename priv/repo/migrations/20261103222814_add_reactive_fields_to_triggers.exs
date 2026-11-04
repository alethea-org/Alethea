defmodule Alethea.Repo.Migrations.AddReactiveFieldsToTriggers do
  use Ecto.Migration

  # Issue #448: reactive triggers share the `triggers` table with active
  # (scheduled) ones. The row shape each kind needs is enforced by CHECK
  # constraints, so a reactive row can never carry a schedule and an active
  # row can never carry a condition. `condition` is patient-encrypted like
  # `instruction`.

  def up do
    alter table(:triggers) do
      add :kind, :string, null: false, default: "active"
      add :condition, :binary
      add :cooldown_hours, :integer
      modify :scheduled_at, :utc_datetime, null: true
      modify :schedule_type, :string, null: true, default: nil
      modify :timezone, :string, null: true
    end

    create constraint(:triggers, :triggers_kind_check, check: "kind IN ('active', 'reactive')")

    create constraint(:triggers, :triggers_active_shape_check,
             check:
               "kind <> 'active' OR (scheduled_at IS NOT NULL AND timezone IS NOT NULL " <>
                 "AND schedule_type IS NOT NULL AND condition IS NULL)"
           )

    create constraint(:triggers, :triggers_reactive_shape_check,
             check:
               "kind <> 'reactive' OR (condition IS NOT NULL AND cooldown_hours IS NOT NULL " <>
                 "AND scheduled_at IS NULL AND schedule_type IS NULL)"
           )

    create index(:triggers, [:patient_id, :kind, :status])
    create unique_index(:trigger_firings, [:trigger_id, :message_id])
  end

  def down do
    # Restoring NOT NULL on the schedule columns would fail on reactive rows.
    # They hold clinical configuration, so the rollback refuses instead of
    # deleting them; remove them deliberately before rolling back.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM triggers WHERE kind = 'reactive') THEN
        RAISE EXCEPTION 'cannot roll back: reactive triggers exist; remove them first';
      END IF;
    END
    $$;
    """)

    drop unique_index(:trigger_firings, [:trigger_id, :message_id])
    drop index(:triggers, [:patient_id, :kind, :status])
    drop constraint(:triggers, :triggers_reactive_shape_check)
    drop constraint(:triggers, :triggers_active_shape_check)
    drop constraint(:triggers, :triggers_kind_check)

    alter table(:triggers) do
      modify :scheduled_at, :utc_datetime, null: false
      modify :timezone, :string, null: false
      modify :schedule_type, :string, null: false, default: "once"
      remove :cooldown_hours
      remove :condition
      remove :kind
    end
  end
end
