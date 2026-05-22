defmodule AletheaWeb.LoginLiveTest do
  use AletheaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alethea.Accounts

  @valid_attrs %{
    email: "psicologo@example.com",
    password: "contraseña_segura_123",
    full_name: "Dra. Ana García"
  }

  defp create_professional do
    {:ok, professional} = Accounts.create_professional(@valid_attrs)
    professional
  end

  defp log_in(conn, professional) do
    conn |> Plug.Test.init_test_session(%{professional_id: professional.id})
  end

  describe "GET /login" do
    test "renders login form when unauthenticated", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/login")
      assert html =~ "Iniciar sesión"
      assert html =~ "Correo electrónico"
      assert html =~ "Contraseña"
    end

    test "redirects to dashboard when already authenticated", %{conn: conn} do
      professional = create_professional()
      conn = log_in(conn, professional)

      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/login")
    end
  end

  describe "GET /dashboard" do
    test "redirects to login when unauthenticated", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")
      assert redirected_to(conn) == "/login"
    end

    test "stores return_to path in session before redirecting", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")
      assert get_session(conn, :return_to) == "/dashboard"
    end

    test "renders when authenticated", %{conn: conn} do
      professional = create_professional()
      conn = log_in(conn, professional)

      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dashboard"
      assert html =~ professional.full_name
    end
  end

  describe "POST /login" do
    test "sets session and redirects to dashboard on valid credentials", %{conn: conn} do
      professional = create_professional()

      conn =
        post(conn, ~p"/login", %{
          "professional" => %{
            "email" => professional.email,
            "password" => @valid_attrs.password
          }
        })

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :professional_id) == professional.id
    end

    test "redirects to return_to path when set in session", %{conn: conn} do
      professional = create_professional()

      conn =
        conn
        |> Plug.Test.init_test_session(%{return_to: "/dashboard"})
        |> post(~p"/login", %{
          "professional" => %{
            "email" => professional.email,
            "password" => @valid_attrs.password
          }
        })

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :return_to) == nil
    end

    test "redirects back to login with error flash on wrong password", %{conn: conn} do
      create_professional()

      conn =
        post(conn, ~p"/login", %{
          "professional" => %{
            "email" => @valid_attrs.email,
            "password" => "contraseña_incorrecta_999"
          }
        })

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :professional_id) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "incorrectos"
    end

    test "redirects back to login on unknown email", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "professional" => %{
            "email" => "noexiste@example.com",
            "password" => "cualquier_contraseña"
          }
        })

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :professional_id) == nil
    end
  end

  describe "DELETE /logout" do
    test "clears session and redirects to login", %{conn: conn} do
      professional = create_professional()
      conn = log_in(conn, professional)

      conn = delete(conn, ~p"/logout")
      assert redirected_to(conn) == "/login"
      assert get_session(conn, :professional_id) == nil
    end
  end
end
