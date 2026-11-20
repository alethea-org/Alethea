defmodule AletheaWeb.BillingGateTest do
  @moduledoc """
  The paid-access gate (#502) and the `/billing` page (#503, #504): who
  reaches the clinical workspace, what a lapsed professional can still do,
  the checkout "processing" state, live unlock, status and customer portal.
  """
  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AletheaWeb.BillingHelpers

  alias Alethea.Accounts
  alias Alethea.Billing.Subscription
  alias Alethea.Repo

  setup %{conn: conn} do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "gate-#{System.unique_integer([:positive])}@alethea.com",
        password: "password1234",
        full_name: "Dra. Gate"
      })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:professional_id, professional.id)

    %{conn: conn, professional: professional}
  end

  defp put_subscription(professional, attrs) do
    %Subscription{professional_id: professional.id}
    |> Subscription.changeset(
      Map.merge(
        %{
          paddle_subscription_id: "sub_#{System.unique_integer([:positive])}",
          paddle_customer_id: "ctm_gate",
          price_id: price_id(),
          status: "active",
          current_period_ends_at:
            DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second),
          last_event_occurred_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp past, do: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
  defp future, do: DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

  describe "billing enabled" do
    setup :enable_billing

    test "professional without a subscription is redirected from the workspace to /billing",
         %{conn: conn} do
      for path <- ["/dashboard", "/patients", "/patients/new"] do
        assert redirected_to(get(conn, path)) == "/billing", "#{path} should be gated"
      end

      assert {:error, {:redirect, %{to: "/billing"}}} = live(conn, "/patients")
    end

    test "active, trialing and past_due subscriptions reach the workspace",
         %{conn: conn, professional: p} do
      sub = put_subscription(p, %{status: "active"})

      for status <- ["active", "trialing", "past_due"] do
        sub |> Ecto.Changeset.change(status: status) |> Repo.update!()
        assert html_response(get(conn, "/patients"), 200), "#{status} should be entitled"
      end
    end

    test "canceled with the paid period still running is entitled", %{conn: conn, professional: p} do
      put_subscription(p, %{status: "canceled", current_period_ends_at: future()})

      assert html_response(get(conn, "/patients"), 200)
    end

    test "canceled after the period end and paused are not entitled",
         %{conn: conn, professional: p} do
      sub = put_subscription(p, %{status: "canceled", current_period_ends_at: past()})
      assert redirected_to(get(conn, "/patients")) == "/billing"

      sub
      |> Ecto.Changeset.change(status: "paused", current_period_ends_at: future())
      |> Repo.update!()

      assert redirected_to(get(conn, "/patients")) == "/billing"
    end

    test "a lapsed professional can open /billing and log out", %{conn: conn, professional: p} do
      put_subscription(p, %{status: "canceled", current_period_ends_at: past()})

      {:ok, view, html} = live(conn, "/billing")
      assert html =~ "Cancelada"
      assert has_element?(view, "#billing-plans")
      assert has_element?(view, "#billing-logout")

      assert redirected_to(delete(conn, "/logout")) =~ "/"
    end

    test "/billing lists the configured plans with a Spanish overlay checkout config",
         %{conn: conn, professional: p} do
      {:ok, view, _html} = live(conn, "/billing")

      assert has_element?(view, "#plan-#{price_id()} [data-checkout='#{price_id()}']")

      config =
        view
        |> element("#billing-plans")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-config")
        |> List.first()
        |> Jason.decode!()

      assert config["email"] == p.email
      assert config["custom_data"] == %{"professional_id" => p.id}
      assert config["price_ids"] == [price_id()]
      assert config["client_token"] == "test_client_token"
      assert config["environment"] == "sandbox"
    end

    test "after checkout the page shows a processing state, then unlocks when the webhook lands",
         %{conn: conn, professional: p} do
      {:ok, view, _html} = live(conn, "/billing")

      view |> element("#billing-plans") |> render_hook("checkout_completed", %{})
      assert has_element?(view, "#billing-processing")
      refute has_element?(view, "#billing-plans")

      post_paddle(build_conn(), subscription_event("subscription.activated", p.id))
      Oban.drain_queue(queue: :billing)

      assert_redirect(view, "/dashboard")
    end

    test "a subscribed professional sees status, next billing date and the portal link",
         %{conn: conn, professional: p} do
      ends_at = future()
      put_subscription(p, %{status: "active", current_period_ends_at: ends_at})

      {:ok, view, _html} = live(conn, "/billing")

      assert render(element(view, "#billing-status")) =~ "Activa"
      assert render(element(view, "#billing-period")) =~ "Próximo cobro"
      assert render(element(view, "#billing-period")) =~ Calendar.strftime(ends_at, "%d/%m/%Y")
      refute has_element?(view, "#billing-plans")

      Req.Test.stub(Alethea.Billing, fn req_conn ->
        assert req_conn.request_path == "/customers/ctm_gate/portal-sessions"
        assert Plug.Conn.get_req_header(req_conn, "authorization") == ["Bearer pdl_test_api_key"]

        Req.Test.json(req_conn, %{
          "data" => %{
            "urls" => %{"general" => %{"overview" => "https://customer-portal.paddle.com/cpl_1"}}
          }
        })
      end)

      Req.Test.allow(Alethea.Billing, self(), view.pid)

      assert {:error, {:redirect, %{to: "https://customer-portal.paddle.com/cpl_1"}}} =
               view |> element("#billing-portal") |> render_click()
    end

    test "a scheduled cancellation shows when access ends", %{conn: conn, professional: p} do
      put_subscription(p, %{status: "active", cancel_at_period_end: true})

      {:ok, view, _html} = live(conn, "/billing")
      assert render(element(view, "#billing-period")) =~ "Acceso hasta"
    end
  end

  describe "billing disabled" do
    test "every professional reaches the workspace without a subscription", %{conn: conn} do
      assert html_response(get(conn, "/patients"), 200)
    end

    test "/billing says billing is not active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/billing")
      assert has_element?(view, "#billing-disabled")
    end
  end
end
