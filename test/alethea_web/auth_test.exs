defmodule AletheaWeb.AuthTest do
  use AletheaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alethea.Accounts

  @password "password12345"
  @remember_cookie "_alethea_remember_me"
  @remember_max_age 30 * 24 * 60 * 60

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "test-#{System.unique_integer()}@alethea.com",
        full_name: "Test User",
        password: @password
      })

    %{professional: professional}
  end

  describe "Protección de rutas" do
    test "redirige a login cuando no está autenticado", %{conn: conn} do
      conn = get(conn, "/dashboard")
      assert redirected_to(conn) == "/login"
    end

    test "permite acceso cuando está autenticado", %{conn: conn, professional: professional} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{professional_id: professional.id})
        |> get("/dashboard")

      assert html_response(conn, 200) =~ "Dashboard"
      assert html_response(conn, 200) =~ professional.full_name
    end
  end

  describe "Login y Logout" do
    @tag :skip
    test "login con credenciales válidas via LiveView redirects to session controller", %{
      conn: conn,
      professional: professional
    } do
      {:ok, view, _html} = live(conn, "/login")

      view
      |> element("form")
      |> render_submit(%{professional: %{email: professional.email, password: @password}})

      # LiveView redirects to session controller which sets session and redirects to dashboard
    end

    test "login con credenciales válidas via controller", %{
      conn: conn,
      professional: professional
    } do
      conn =
        post(conn, "/login", %{
          "professional" => %{"email" => professional.email, "password" => @password}
        })

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :professional_id) == professional.id
    end

    test "login con remember me crea una cookie persistente segura", %{
      conn: conn,
      professional: professional
    } do
      conn = login_with_remember(conn, professional)

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :professional_id) == professional.id

      remember_cookie = conn.resp_cookies[@remember_cookie]

      assert remember_cookie.value
      assert remember_cookie.http_only
      assert remember_cookie.secure
      assert remember_cookie.same_site == "Lax"
      assert remember_cookie.max_age == @remember_max_age

      professional = Accounts.get_professional!(professional.id)
      assert is_binary(professional.remember_token_hash)
      assert %DateTime{} = professional.remember_token_expires_at
    end

    test "autentica con cookie remember y rota el token", %{
      conn: conn,
      professional: professional
    } do
      login_conn = login_with_remember(conn, professional)
      old_token = login_conn.resp_cookies[@remember_cookie].value

      conn =
        build_conn()
        |> Plug.Conn.put_req_cookie(@remember_cookie, old_token)
        |> get("/dashboard")

      assert html_response(conn, 200) =~ "Dashboard"
      assert get_session(conn, :professional_id) == professional.id

      rotated_token = conn.resp_cookies[@remember_cookie].value
      assert rotated_token
      assert rotated_token != old_token

      replay_conn =
        build_conn()
        |> Plug.Conn.put_req_cookie(@remember_cookie, old_token)
        |> get("/dashboard")

      assert redirected_to(replay_conn) == "/login"

      rotated_conn =
        build_conn()
        |> Plug.Conn.put_req_cookie(@remember_cookie, rotated_token)
        |> get("/dashboard")

      assert html_response(rotated_conn, 200) =~ "Dashboard"
    end

    test "login con credenciales inválidas", %{conn: conn, professional: professional} do
      conn =
        post(conn, "/login", %{
          "professional" => %{"email" => professional.email, "password" => "wrong_password"}
        })

      assert redirected_to(conn) == "/login"
    end

    test "logout limpia la sesión", %{conn: conn, professional: professional} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{professional_id: professional.id})

      conn = delete(conn, "/logout")
      assert redirected_to(conn) == "/login"
    end

    test "logout limpia la cookie remember e invalida el token", %{
      conn: conn,
      professional: professional
    } do
      login_conn = login_with_remember(conn, professional)
      remember_token = login_conn.resp_cookies[@remember_cookie].value

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{professional_id: professional.id})
        |> Plug.Conn.put_req_cookie(@remember_cookie, remember_token)
        |> delete("/logout")

      assert redirected_to(conn) == "/login"
      assert conn.resp_cookies[@remember_cookie].max_age == 0

      professional = Accounts.get_professional!(professional.id)
      refute professional.remember_token_hash
      refute professional.remember_token_expires_at

      conn =
        build_conn()
        |> Plug.Conn.put_req_cookie(@remember_cookie, remember_token)
        |> get("/dashboard")

      assert redirected_to(conn) == "/login"
    end
  end

  describe "Registro" do
    test "renderiza el formulario de registro", %{conn: conn} do
      conn = get(conn, "/register")
      html = html_response(conn, 200)
      assert html =~ "Crear tu cuenta"
      assert html =~ "Correo electrónico"
      assert html =~ "Nombre completo"
      assert html =~ "Contraseña"
    end

    test "crea un nuevo profesional via controller", %{conn: conn} do
      email = "new-#{System.unique_integer()}@alethea.com"

      conn =
        post(conn, "/register", %{
          "professional" => %{
            "email" => email,
            "full_name" => "New Pro",
            "password" => @password
          }
        })

      assert redirected_to(conn) == "/login"
      assert Accounts.get_professional_by_email(email)
    end
  end

  defp login_with_remember(conn, professional) do
    post(conn, "/login", %{
      "professional" => %{
        "email" => professional.email,
        "password" => @password,
        "remember_me" => "true"
      }
    })
  end
end
