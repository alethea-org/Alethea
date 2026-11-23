defmodule AletheaWeb.PaddleWebhookController do
  @moduledoc """
  Inbound Paddle Billing webhook (`POST /webhooks/paddle`).

  The `PaddleSignature` plug has already verified the request. The
  controller acknowledges with 200 immediately and enqueues
  `Alethea.Jobs.PaddleEventWorker` with the payload; Paddle retries any
  notification that is not acknowledged quickly. A verified payload
  without an `event_id` / `event_type` is acknowledged and dropped,
  since retrying it cannot help.
  """
  use AletheaWeb, :controller

  alias Alethea.Jobs.PaddleEventWorker

  def create(conn, %{"event_id" => event_id, "event_type" => event_type} = payload)
      when is_binary(event_id) and is_binary(event_type) do
    payload =
      Map.take(payload, ["event_id", "event_type", "occurred_at", "notification_id", "data"])

    {:ok, _job} =
      %{event_id: event_id, payload: payload}
      |> PaddleEventWorker.new()
      |> Oban.insert()

    send_resp(conn, 200, "")
  end

  def create(conn, _params), do: send_resp(conn, 200, "")
end
