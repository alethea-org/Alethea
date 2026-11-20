defmodule AletheaWeb.BillingHelpers do
  @moduledoc """
  Test helpers for Paddle Billing: enable billing with test credentials and
  build signed Paddle webhook notifications.
  """

  import Plug.Conn
  import Phoenix.ConnTest

  alias Alethea.Billing.Signature

  @endpoint AletheaWeb.Endpoint
  @webhook_secret "pdl_ntfset_test_secret"
  @price_id "pri_test_monthly"

  def webhook_secret, do: @webhook_secret
  def price_id, do: @price_id

  @doc "Enables billing for the current test and restores the previous config."
  def enable_billing(_context \\ %{}) do
    previous = Application.get_env(:alethea, Alethea.Billing)

    Application.put_env(:alethea, Alethea.Billing,
      enabled: true,
      environment: "sandbox",
      webhook_secret: @webhook_secret,
      api_key: "pdl_test_api_key",
      client_token: "test_client_token",
      price_ids: [@price_id],
      req_options: [plug: {Req.Test, Alethea.Billing}]
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:alethea, Alethea.Billing, previous) end)
    :ok
  end

  @doc "A Paddle `subscription.*` notification payload."
  def subscription_event(type, professional_id, overrides \\ %{}) do
    occurred_at = Map.get(overrides, :occurred_at, DateTime.utc_now())

    data =
      %{
        "id" => Map.get(overrides, :subscription_id, "sub_test_1"),
        "status" => Map.get(overrides, :status, "active"),
        "customer_id" => "ctm_test_1",
        "custom_data" => %{"professional_id" => professional_id},
        "items" => [%{"price" => %{"id" => @price_id}, "quantity" => 1}],
        "current_billing_period" => %{
          "starts_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "ends_at" =>
            overrides
            |> Map.get(:period_ends_at, DateTime.add(DateTime.utc_now(), 30, :day))
            |> iso8601_or_nil()
        },
        "scheduled_change" => Map.get(overrides, :scheduled_change)
      }

    %{
      "event_id" => Map.get(overrides, :event_id, "evt_#{System.unique_integer([:positive])}"),
      "event_type" => type,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "notification_id" => "ntf_#{System.unique_integer([:positive])}",
      "data" => data
    }
  end

  @doc "POSTs `payload` to the Paddle webhook, signed with the test secret."
  def post_paddle(conn, payload, opts \\ []) do
    body = Jason.encode!(payload)
    ts = Keyword.get(opts, :ts, System.system_time(:second))
    secret = Keyword.get(opts, :secret, @webhook_secret)
    header = Keyword.get(opts, :header, "ts=#{ts};h1=#{Signature.sign(body, ts, secret)}")

    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if header, do: put_req_header(conn, "paddle-signature", header), else: conn
    end)
    |> post("/webhooks/paddle", body)
  end

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
