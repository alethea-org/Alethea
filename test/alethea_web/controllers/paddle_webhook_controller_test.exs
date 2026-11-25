defmodule AletheaWeb.PaddleWebhookControllerTest do
  @moduledoc """
  The Paddle webhook contract (`POST /webhooks/paddle`, #500, #501):
  signature verification, fast-ack + Oban hand-off, persisted subscription
  state after the queue drains, idempotency, ordering safety and audit.
  """
  use AletheaWeb.ConnCase, async: false

  import Ecto.Query
  use Oban.Testing, repo: Alethea.Repo
  import AletheaWeb.BillingHelpers

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.Billing.Subscription
  alias Alethea.Jobs.PaddleEventWorker
  alias Alethea.Repo

  setup :enable_billing

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "billing-#{System.unique_integer([:positive])}@alethea.com",
        password: "password1234",
        full_name: "Dra. Paga"
      })

    %{professional: professional}
  end

  defp drain, do: Oban.drain_queue(queue: :billing)

  defp subscription(professional), do: Repo.get_by(Subscription, professional_id: professional.id)

  defp audit_count(professional) do
    from(a in AuditLog,
      where: a.professional_id == ^professional.id and a.action == "BILLING_SUBSCRIPTION_CHANGED"
    )
    |> Repo.aggregate(:count)
  end

  describe "signature verification" do
    test "missing signature → 401, nothing enqueued or persisted", %{conn: conn, professional: p} do
      conn = post_paddle(conn, subscription_event("subscription.created", p.id), header: nil)

      assert conn.status == 401
      assert all_enqueued(worker: PaddleEventWorker) == []
      drain()
      assert subscription(p) == nil
    end

    test "signature made with another secret → 401", %{conn: conn, professional: p} do
      conn = post_paddle(conn, subscription_event("subscription.created", p.id), secret: "wrong")

      assert conn.status == 401
      assert all_enqueued(worker: PaddleEventWorker) == []
    end

    test "signature with a timestamp outside the tolerance → 401", %{conn: conn, professional: p} do
      ts = System.system_time(:second) - 3_600
      conn = post_paddle(conn, subscription_event("subscription.created", p.id), ts: ts)

      assert conn.status == 401
      assert all_enqueued(worker: PaddleEventWorker) == []
    end
  end

  describe "verified notifications" do
    test "subscription.created → 200 and the subscription is persisted after the queue drains",
         %{conn: conn, professional: p} do
      ends_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      conn =
        post_paddle(
          conn,
          subscription_event("subscription.created", p.id, %{period_ends_at: ends_at})
        )

      assert conn.status == 200
      assert [_job] = all_enqueued(worker: PaddleEventWorker)
      assert subscription(p) == nil

      assert %{success: 1} = drain()

      sub = subscription(p)
      assert sub.status == "active"
      assert sub.price_id == price_id()
      assert sub.paddle_subscription_id == "sub_test_1"
      assert sub.paddle_customer_id == "ctm_test_1"
      assert sub.current_period_ends_at == ends_at
      assert sub.cancel_at_period_end == false
    end

    test "verified payload without event_id → 200, acked and dropped", %{conn: conn} do
      conn = post_paddle(conn, %{"event_type" => "subscription.created"})

      assert conn.status == 200
      assert all_enqueued(worker: PaddleEventWorker) == []
    end

    test "event for an unknown professional → acked, nothing persisted", %{conn: conn} do
      conn = post_paddle(conn, subscription_event("subscription.created", Ecto.UUID.generate()))

      assert conn.status == 200
      assert %{success: 1} = drain()
      assert Repo.aggregate(Subscription, :count) == 0
    end

    test "later events are linked through the stored Paddle subscription id",
         %{conn: conn, professional: p} do
      post_paddle(conn, subscription_event("subscription.created", p.id))
      drain()

      past_due =
        subscription_event("subscription.past_due", nil, %{status: "past_due"})
        |> put_in(["data", "custom_data"], nil)

      post_paddle(build_conn(), past_due)
      drain()

      assert subscription(p).status == "past_due"
    end

    test "scheduled cancellation and the final canceled event", %{conn: conn, professional: p} do
      t0 = DateTime.utc_now()
      post_paddle(conn, subscription_event("subscription.created", p.id, %{occurred_at: t0}))

      post_paddle(
        build_conn(),
        subscription_event("subscription.updated", p.id, %{
          occurred_at: DateTime.add(t0, 1, :second),
          scheduled_change: %{"action" => "cancel", "effective_at" => "2099-01-01T00:00:00Z"}
        })
      )

      drain()
      assert subscription(p).cancel_at_period_end

      post_paddle(
        build_conn(),
        subscription_event("subscription.canceled", p.id, %{
          occurred_at: DateTime.add(t0, 2, :second),
          status: "canceled",
          period_ends_at: nil
        })
      )

      drain()
      sub = subscription(p)
      assert sub.status == "canceled"
      # Paddle omits the billing period on cancel; the paid period end is kept.
      assert sub.current_period_ends_at
    end

    test "every handled subscription event maps to its status", %{professional: p} do
      for {type, status} <- [
            {"subscription.trialing", "trialing"},
            {"subscription.activated", "active"},
            {"subscription.past_due", "past_due"},
            {"subscription.paused", "paused"},
            {"subscription.resumed", "active"},
            {"subscription.canceled", "canceled"}
          ] do
        post_paddle(build_conn(), subscription_event(type, p.id, %{status: status}))
        drain()
        assert subscription(p).status == status, "#{type} should store #{status}"
      end
    end

    test "transaction.completed links ids without changing the status",
         %{conn: conn, professional: p} do
      t0 = DateTime.utc_now()

      post_paddle(
        conn,
        subscription_event("subscription.paused", p.id, %{status: "paused", occurred_at: t0})
      )

      drain()

      transaction = %{
        "event_id" => "evt_txn_1",
        "event_type" => "transaction.completed",
        "occurred_at" => DateTime.to_iso8601(DateTime.add(t0, 5, :second)),
        "data" => %{
          "id" => "txn_1",
          "status" => "completed",
          "subscription_id" => "sub_test_1",
          "customer_id" => "ctm_test_1",
          "custom_data" => %{"professional_id" => p.id}
        }
      }

      post_paddle(build_conn(), transaction)
      drain()
      assert subscription(p).status == "paused"

      # A status event that happened before the transaction still applies.
      post_paddle(
        build_conn(),
        subscription_event("subscription.resumed", p.id, %{
          occurred_at: DateTime.add(t0, 1, :second)
        })
      )

      drain()
      assert subscription(p).status == "active"
    end
  end

  describe "idempotency, ordering and audit" do
    test "the same event_id delivered twice is applied once", %{conn: conn, professional: p} do
      event = subscription_event("subscription.created", p.id, %{event_id: "evt_dup"})

      post_paddle(conn, event)
      drain()
      post_paddle(build_conn(), event)
      drain()

      # Durable guard, independent of Oban uniqueness.
      assert :ok = perform_job(PaddleEventWorker, %{event_id: "evt_dup", payload: event})

      assert audit_count(p) == 1
    end

    test "an older event arriving after a newer one does not roll state back",
         %{conn: conn, professional: p} do
      t0 = DateTime.utc_now()

      post_paddle(
        conn,
        subscription_event("subscription.canceled", p.id, %{
          status: "canceled",
          occurred_at: DateTime.add(t0, 10, :second)
        })
      )

      drain()

      post_paddle(
        build_conn(),
        subscription_event("subscription.updated", p.id, %{status: "active", occurred_at: t0})
      )

      drain()

      assert subscription(p).status == "canceled"
      assert audit_count(p) == 1
    end

    test "each applied change writes an audit entry for the professional",
         %{conn: conn, professional: p} do
      t0 = DateTime.utc_now()
      post_paddle(conn, subscription_event("subscription.created", p.id, %{occurred_at: t0}))

      post_paddle(
        build_conn(),
        subscription_event("subscription.past_due", p.id, %{
          status: "past_due",
          occurred_at: DateTime.add(t0, 1, :second)
        })
      )

      drain()

      logs =
        from(a in AuditLog,
          where: a.professional_id == ^p.id and a.action == "BILLING_SUBSCRIPTION_CHANGED",
          order_by: a.inserted_at
        )
        |> Repo.all()

      assert length(logs) == 2

      assert Enum.map(logs, & &1.details["to_status"]) |> Enum.sort() == ["active", "past_due"]
      assert Enum.all?(logs, &(&1.resource_type == "billing_subscription"))
    end
  end

  describe "entitlement requires a configured price" do
    test "an active subscription to a price outside PADDLE_PRICE_IDS grants no access",
         %{conn: conn, professional: p} do
      post_paddle(
        conn,
        subscription_event("subscription.created", p.id, %{price_id: "pri_other"})
      )

      drain()

      assert subscription(p).price_id == "pri_other"
      assert subscription(p).status == "active"
      refute Alethea.Billing.entitled?(p)
    end

    test "an active subscription to a configured price still grants access",
         %{conn: conn, professional: p} do
      post_paddle(conn, subscription_event("subscription.created", p.id))
      drain()

      assert Alethea.Billing.entitled?(p)
    end

    test "a canceled subscription to a configured price keeps access until the period ends",
         %{conn: conn, professional: p} do
      post_paddle(conn, subscription_event("subscription.canceled", p.id, %{status: "canceled"}))
      drain()

      assert Alethea.Billing.entitled?(p)
    end
  end

  describe "linking a Paddle subscription to a professional" do
    test "a late event from an abandoned subscription does not take over the new one",
         %{conn: conn, professional: p} do
      t0 = DateTime.add(DateTime.utc_now(), -3600, :second)

      post_paddle(
        conn,
        subscription_event("subscription.paused", p.id, %{
          subscription_id: "sub_A",
          status: "paused",
          occurred_at: t0
        })
      )

      drain()
      refute Alethea.Billing.entitled?(p)

      post_paddle(
        build_conn(),
        subscription_event("subscription.created", p.id, %{
          subscription_id: "sub_B",
          occurred_at: DateTime.add(t0, 60, :second)
        })
      )

      drain()
      assert Alethea.Billing.entitled?(p)

      post_paddle(
        build_conn(),
        subscription_event("subscription.canceled", p.id, %{
          subscription_id: "sub_A",
          status: "canceled",
          period_ends_at: nil,
          occurred_at: DateTime.add(t0, 120, :second)
        })
      )

      drain()

      sub = subscription(p)
      assert sub.paddle_subscription_id == "sub_B"
      assert sub.status == "active"
    end

    test "custom_data without the server-issued link token cannot claim a professional",
         %{conn: conn, professional: victim} do
      post_paddle(
        conn,
        subscription_event("subscription.created", victim.id, %{subscription_id: "sub_V"})
      )

      drain()

      for token <- [nil, "forged", Alethea.Billing.link_token(Ecto.UUID.generate())] do
        post_paddle(
          build_conn(),
          subscription_event("subscription.created", victim.id, %{
            subscription_id: "sub_X_#{System.unique_integer([:positive])}",
            status: "canceled",
            period_ends_at: nil,
            link_token: token
          })
        )

        drain()
      end

      sub = subscription(victim)
      assert sub.paddle_subscription_id == "sub_V"
      assert sub.status == "active"
      assert audit_count(victim) == 1
    end

    test "a transaction that arrives before its subscription event does not block it",
         %{conn: conn, professional: p} do
      t0 = DateTime.utc_now()
      ends_at = t0 |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      transaction = %{
        "event_id" => "evt_txn_first",
        "event_type" => "transaction.completed",
        "occurred_at" => DateTime.to_iso8601(DateTime.add(t0, 5, :second)),
        "data" => %{
          "id" => "txn_first",
          "subscription_id" => "sub_test_1",
          "customer_id" => "ctm_test_1",
          "custom_data" => %{
            "professional_id" => p.id,
            "link_token" => Alethea.Billing.link_token(p.id)
          }
        }
      }

      post_paddle(conn, transaction)
      drain()
      assert subscription(p) == nil

      post_paddle(
        build_conn(),
        subscription_event("subscription.activated", p.id, %{
          occurred_at: t0,
          period_ends_at: ends_at
        })
      )

      drain()

      sub = subscription(p)
      assert sub.status == "active"
      assert sub.current_period_ends_at == ends_at
      assert sub.price_id == price_id()
    end
  end
end
