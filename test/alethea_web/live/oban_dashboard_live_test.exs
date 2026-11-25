defmodule AletheaWeb.ObanDashboardLiveTest do
  @moduledoc """
  `/admin/oban-dashboard` exposes every tenant's job args and lets the
  viewer cancel or retry any job, so it is an operator page: only
  professionals listed in ADMIN_EMAILS get in, exactly like
  `/admin/waitlist`.
  """

  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alethea.RagFixtures, only: [create_professional!: 0]

  alias Alethea.Repo

  setup %{conn: conn} do
    previous = Application.get_env(:alethea, :admin_emails)
    on_exit(fn -> Application.put_env(:alethea, :admin_emails, previous) end)

    professional = create_professional!()

    {:ok, job} =
      %{"telegram_update_id" => 1, "message" => %{"text" => "DUMMY-A-TEXT"}}
      |> Oban.Job.new(worker: "Alethea.Jobs.TelegramMessageWorker", queue: :default)
      |> Repo.insert()

    %{conn: log_in(conn, professional), professional: professional, job: job}
  end

  defp log_in(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end

  describe "a professional who is not an admin" do
    setup do
      Application.put_env(:alethea, :admin_emails, ["someone-else@example.com"])
      :ok
    end

    test "gets the same 404 as the other /admin pages", %{conn: conn} do
      waitlist = conn |> get(~p"/admin/waitlist") |> html_response(404)
      dashboard = conn |> get(~p"/admin/oban-dashboard") |> html_response(404)

      assert dashboard =~ "Esta página no existe"
      assert dashboard == waitlist
      refute dashboard =~ "DUMMY-A-TEXT"
    end

    test "never gets a LiveView to send cancel_job to", %{conn: conn, job: job} do
      # The static GET is refused, so no signed LiveView session is ever
      # issued and no socket can join to push `cancel_job`; the mount
      # re-check below covers a socket that reaches `mount/3` anyway.
      assert conn |> get(~p"/admin/oban-dashboard") |> response(404)
      assert Repo.get!(Oban.Job, job.id).state == "available"
    end
  end

  test "with no admin configured nobody gets in", %{conn: conn} do
    Application.put_env(:alethea, :admin_emails, [])

    assert conn |> get(~p"/admin/oban-dashboard") |> html_response(404)
  end

  test "a visitor who is not logged in is sent to the login page" do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/admin/oban-dashboard")
  end

  describe "an admin" do
    setup %{professional: professional} do
      Application.put_env(:alethea, :admin_emails, [String.upcase(professional.email)])
      :ok
    end

    test "sees the jobs and can cancel one", %{conn: conn, job: job} do
      {:ok, view, html} = live(conn, ~p"/admin/oban-dashboard")

      assert html =~ "Cola de trabajos"
      assert has_element?(view, "#jobs", "DUMMY-A-TEXT")

      view
      |> element("button[phx-click='cancel_job'][phx-value-job_id='#{job.id}']")
      |> render_click()

      assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    end
  end

  describe "the mount-time admin re-check" do
    test "redirects a non-admin even when the router hooks are bypassed", %{
      professional: professional
    } do
      Application.put_env(:alethea, :admin_emails, ["someone-else@example.com"])

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_professional: professional, flash: %{}}
      }

      assert {:ok, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/dashboard"}}}} =
               AletheaWeb.ObanDashboardLive.mount(%{}, %{}, socket)
    end
  end
end
