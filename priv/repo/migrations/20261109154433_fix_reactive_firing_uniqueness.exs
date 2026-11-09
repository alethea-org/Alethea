defmodule Alethea.Repo.Migrations.FixReactiveFiringUniqueness do
  use Ecto.Migration

  def up do
    alter table(:trigger_firings) do
      add :kind, :string, null: false, default: "active"
    end

    execute("""
    UPDATE trigger_firings tf
    SET kind = t.kind
    FROM triggers t
    WHERE tf.trigger_id = t.id;
    """)

    drop index(:trigger_firings, [:trigger_id, :scheduled_at],
           name: :trigger_firings_trigger_id_scheduled_at_index
         )

    create unique_index(:trigger_firings, [:trigger_id, :scheduled_at],
             where: "kind = 'active'",
             name: :trigger_firings_trigger_id_scheduled_at_index
           )
  end

  def down do
    drop index(:trigger_firings, [:trigger_id, :scheduled_at],
           name: :trigger_firings_trigger_id_scheduled_at_index
         )

    create unique_index(:trigger_firings, [:trigger_id, :scheduled_at],
             name: :trigger_firings_trigger_id_scheduled_at_index
           )

    alter table(:trigger_firings) do
      remove :kind
    end
  end
end
