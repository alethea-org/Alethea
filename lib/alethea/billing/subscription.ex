defmodule Alethea.Billing.Subscription do
  @moduledoc """
  A professional's Paddle Billing subscription, as last reported by a
  verified Paddle webhook. One row per professional: resubscribing after a
  lapse replaces the Paddle ids on the same row.

  Paddle webhooks are the single source of truth for this record; the
  browser checkout result never writes here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(trialing active past_due paused canceled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "billing_subscriptions" do
    field :paddle_customer_id, :string
    field :paddle_subscription_id, :string
    field :price_id, :string
    field :status, :string
    field :current_period_ends_at, :utc_datetime
    field :cancel_at_period_end, :boolean, default: false
    field :last_event_occurred_at, :utc_datetime_usec

    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :paddle_customer_id,
      :paddle_subscription_id,
      :price_id,
      :status,
      :current_period_ends_at,
      :cancel_at_period_end,
      :last_event_occurred_at
    ])
    |> validate_required([:paddle_subscription_id, :status, :last_event_occurred_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:professional_id)
    |> unique_constraint(:paddle_subscription_id)
  end
end
