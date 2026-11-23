defmodule Alethea.Billing.ProcessedEvent do
  @moduledoc """
  Durable idempotency record: one row per Paddle `event_id` that
  `Alethea.Billing.apply_event/1` has handled (applied, stale, or
  unlinked). A redelivered event finds its row and is skipped.
  """
  use Ecto.Schema

  @primary_key {:event_id, :string, autogenerate: false}
  schema "billing_processed_events" do
    field :event_type, :string
    field :outcome, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
