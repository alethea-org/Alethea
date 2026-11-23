defmodule AletheaWeb.AdminWaitlistLiveTest do
  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Alethea.RagFixtures, only: [create_professional!: 0]

  alias Alethea.Waitlist

  setup %{conn: conn} do
    previous = Application.get_env(:alethea, :admin_emails)
    on_exit(fn -> Application.put_env(:alethea, :admin_emails, previous) end)

    professional = create_professional!()
    %{conn: log_in(conn, professional), professional: professional}
  end

  defp make_admin(professional) do
    Application.put_env(:alethea, :admin_emails, [String.upcase(professional.email)])
  end

  defp log_in(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end

  describe "GET /admin/waitlist" do
    test "an admin sees every signup, newest first, with the total", %{
      conn: conn,
      professional: professional
    } do
      make_admin(professional)
      :ok = Waitlist.join(%{"name" => "Laura Méndez", "email" => "laura@example.com"})
      :ok = Waitlist.join(%{"name" => "Pedro Gómez", "email" => "pedro@example.com"})

      # Timestamps have second precision: make Laura clearly older.
      Alethea.Repo.update_all(
        from(e in Alethea.Waitlist.Entry, where: e.email == "laura@example.com"),
        set: [inserted_at: ~U[2026-01-01 10:00:00Z]]
      )

      {:ok, view, html} = live(conn, ~p"/admin/waitlist")

      assert html =~ "2 personas"
      assert has_element?(view, "#waitlist-entries", "laura@example.com")
      assert has_element?(view, "#waitlist-entries", "Pedro Gómez")
      assert has_element?(view, "a#waitlist-export[href='/admin/waitlist.csv']")

      [first, second] =
        Regex.scan(~r/(laura|pedro)@example\.com/, html) |> Enum.map(&hd/1) |> Enum.dedup()

      assert {first, second} == {"pedro@example.com", "laura@example.com"}
    end

    test "an empty list says so", %{conn: conn, professional: professional} do
      make_admin(professional)
      {:ok, view, _html} = live(conn, ~p"/admin/waitlist")
      assert has_element?(view, "#waitlist-empty")
    end

    test "a professional who is not an admin gets a 404", %{conn: conn} do
      Application.put_env(:alethea, :admin_emails, ["someone-else@example.com"])

      assert conn |> get(~p"/admin/waitlist") |> html_response(404) =~ "Esta página no existe"
    end

    test "with no admin configured nobody gets in", %{conn: conn} do
      Application.put_env(:alethea, :admin_emails, [])

      assert conn |> get(~p"/admin/waitlist") |> html_response(404)
    end

    test "a visitor who is not logged in is sent to the login page" do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/admin/waitlist")
    end
  end

  describe "GET /admin/waitlist.csv" do
    test "an admin downloads every signup as CSV", %{conn: conn, professional: professional} do
      make_admin(professional)
      :ok = Waitlist.join(%{"name" => "Laura, \"Lau\" Méndez", "email" => "laura@example.com"})
      :ok = Waitlist.join(%{"name" => "=HYPERLINK(\"x\")", "email" => "evil@example.com"})

      conn = get(conn, ~p"/admin/waitlist.csv")

      assert response_content_type(conn, :csv) =~ "text/csv"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "lista-de-espera"

      [header | rows] = conn |> response(200) |> String.split("\r\n", trim: true)
      assert header == "nombre,email,fecha"

      assert Enum.any?(
               rows,
               &String.starts_with?(&1, ~s|"Laura, ""Lau"" Méndez",laura@example.com,|)
             )

      # A cell starting with "=" is neutralised so spreadsheets don't run it as a formula.
      assert Enum.any?(rows, &String.starts_with?(&1, ~s|"'=HYPERLINK(""x"")",evil@example.com,|))
    end

    test "a professional who is not an admin gets a 404", %{conn: conn} do
      Application.put_env(:alethea, :admin_emails, [])
      conn = get(conn, ~p"/admin/waitlist.csv")
      assert response(conn, 404)
    end
  end
end
