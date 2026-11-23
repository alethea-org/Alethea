defmodule Alethea.Repo.Migrations.CreateBillingSubscriptions do
  use Ecto.Migration

  def change do
    create table(:billing_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :professional_id, references(:professionals, type: :binary_id, on_delete: :restrict),
        null: false

      add :paddle_customer_id, :string
      add :paddle_subscription_id, :string, null: false
      add :price_id, :string
      add :status, :string, null: false
      add :current_period_ends_at, :utc_datetime
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :last_event_occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:billing_subscriptions, [:professional_id])
    create unique_index(:billing_subscriptions, [:paddle_subscription_id])

    create constraint(:billing_subscriptions, :billing_subscriptions_status_check,
             check: "status IN ('trialing', 'active', 'past_due', 'paused', 'canceled')"
           )

    create table(:billing_processed_events, primary_key: false) do
      add :event_id, :string, primary_key: true
      add :event_type, :string, null: false
      add :outcome, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
