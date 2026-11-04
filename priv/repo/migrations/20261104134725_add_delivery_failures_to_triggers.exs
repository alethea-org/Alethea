defmodule Alethea.Repo.Migrations.AddDeliveryFailuresToTriggers do
  use Ecto.Migration

  def up do
    alter table(:triggers) do
      add :consecutive_delivery_failures, :integer, null: false, default: 0
    end

    drop_if_exists constraint(:trigger_firings, :trigger_firings_status_message_check)

    create constraint(:trigger_firings, :trigger_firings_status_message_check,
             check:
               "(status IN ('fired', 'not_delivered') AND message_id IS NOT NULL) OR (status = 'skipped' AND message_id IS NULL)"
           )
  end

  def down do
    drop_if_exists constraint(:trigger_firings, :trigger_firings_status_message_check)

    create constraint(:trigger_firings, :trigger_firings_status_message_check,
             check:
               "(status = 'fired' AND message_id IS NOT NULL) OR (status = 'skipped' AND message_id IS NULL)"
           )

    alter table(:triggers) do
      remove :consecutive_delivery_failures
    end
  end
end
