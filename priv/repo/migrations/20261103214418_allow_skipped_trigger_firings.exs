defmodule Alethea.Repo.Migrations.AllowSkippedTriggerFirings do
  use Ecto.Migration

  def up do
    alter table(:trigger_firings) do
      modify :message_id, references(:messages, on_delete: :delete_all, type: :binary_id),
        null: true,
        from: references(:messages, on_delete: :delete_all, type: :binary_id)
    end

    create constraint(:trigger_firings, :trigger_firings_status_message_check,
             check:
               "(status = 'fired' AND message_id IS NOT NULL) OR (status = 'skipped' AND message_id IS NULL)"
           )
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM trigger_firings WHERE message_id IS NULL) THEN
        RAISE EXCEPTION 'Cannot roll back allow_skipped_trigger_firings: trigger_firings with null message_id exist and cannot be made non-null without deleting skipped history';
      END IF;
    END $$;
    """

    drop_if_exists constraint(:trigger_firings, :trigger_firings_status_message_check)

    alter table(:trigger_firings) do
      modify :message_id, references(:messages, on_delete: :delete_all, type: :binary_id),
        null: false,
        from: references(:messages, on_delete: :delete_all, type: :binary_id)
    end
  end
end
