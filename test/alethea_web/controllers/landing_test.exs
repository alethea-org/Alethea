defmodule AletheaWeb.LandingTest do
  use AletheaWeb.ConnCase, async: true

  alias Alethea.Repo
  alias Alethea.Waitlist.Entry

  describe "GET /" do
    test "renders the tour scenes, the waitlist form and no LiveView socket", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      doc = LazyHTML.from_document(html)

      for id <- ~w(invitacion diario emociones crisis briefing historia-clinica sesiones
                   analisis-funcional notas privacidad lista-de-espera) do
        assert LazyHTML.query(doc, "##{id}") |> Enum.count() == 1, "missing ##{id}"
      end

      assert LazyHTML.query(doc, "#waitlist-form[action='/waitlist']") |> Enum.count() == 1
      assert LazyHTML.query(doc, "a.lx-dot") |> Enum.count() == 10
      assert html =~ "/assets/js/landing.js"
      refute html =~ "phoenix_live_view.js"
    end
  end

  describe "login link" do
    setup do
      previous = Application.get_env(:alethea, :demo_restricted_access)
      on_exit(fn -> Application.put_env(:alethea, :demo_restricted_access, previous) end)
    end

    test "is hidden from the landing while access is restricted", %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, true)
      refute conn |> get(~p"/") |> html_response(200) =~ ~s(href="/login")
    end

    test "is shown on the landing when access is open", %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, false)
      assert conn |> get(~p"/") |> html_response(200) =~ ~s(href="/login")
    end
  end

  describe "POST /waitlist" do
    test "stores a normalised entry and confirms", %{conn: conn} do
      conn =
        post(conn, ~p"/waitlist", %{
          "waitlist" => %{
            "name" => "  Laura Méndez ",
            "email" => " Laura@Example.com ",
            "website" => ""
          }
        })

      assert redirected_to(conn) == "/#lista-de-espera"
      assert [%Entry{name: "Laura Méndez", email: "laura@example.com"}] = Repo.all(Entry)

      html = conn |> recycle() |> get(~p"/") |> html_response(200)
      assert html =~ "Te avisamos por email"
      refute html =~ ~s(id="waitlist-form")
    end

    test "the same email twice keeps one entry and still confirms", %{conn: conn} do
      params = %{
        "waitlist" => %{"name" => "Laura", "email" => "laura@example.com", "website" => ""}
      }

      post(conn, ~p"/waitlist", params)

      again =
        post(build_conn(), ~p"/waitlist", %{
          "waitlist" => %{"name" => "Otra", "email" => "LAURA@example.com", "website" => ""}
        })

      assert redirected_to(again) == "/#lista-de-espera"
      assert [%Entry{name: "Laura"}] = Repo.all(Entry)
    end

    test "invalid input re-renders the form with errors and stores nothing", %{conn: conn} do
      conn =
        post(conn, ~p"/waitlist", %{
          "waitlist" => %{"name" => "", "email" => "no-es-un-email", "website" => ""}
        })

      html = html_response(conn, 422)
      assert html =~ "Contanos tu nombre"
      assert html =~ "Revisá el email"
      assert html =~ ~s(value="no-es-un-email")
      assert Repo.all(Entry) == []
    end

    test "a filled honeypot looks successful but stores nothing", %{conn: conn} do
      conn =
        post(conn, ~p"/waitlist", %{
          "waitlist" => %{
            "name" => "Bot",
            "email" => "bot@example.com",
            "website" => "http://spam"
          }
        })

      assert redirected_to(conn) == "/#lista-de-espera"
      assert Repo.all(Entry) == []
    end
  end
end
