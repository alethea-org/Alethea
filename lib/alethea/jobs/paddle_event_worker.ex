defmodule Alethea.Jobs.PaddleEventWorker do
  @moduledoc """
  Applies one verified Paddle webhook notification to subscription state.

  `AletheaWeb.PaddleWebhookController` fast-acks Paddle and enqueues this
  worker with the verified payload. Oban uniqueness on `event_id` drops
  duplicate enqueues; the `billing_processed_events` row inside
  `Alethea.Billing.apply_event/1` is the durable idempotency guard.
  """
  use Oban.Worker,
    queue: :billing,
    max_attempts: 10,
    unique: [period: 86_400, keys: [:event_id]]

  alias Alethea.Billing
  alias Alethea.Billing.Event

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payload" => payload}}) do
    case Event.from_payload(payload) do
      {:ok, event} ->
        case Billing.apply_event(event) do
          {:ok, _outcome} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ignore, _type} ->
        :ok

      {:error, :malformed} ->
        {:cancel, :malformed}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :malformed}
end
