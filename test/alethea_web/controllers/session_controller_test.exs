defmodule AletheaWeb.SessionControllerTest do
  use AletheaWeb.ConnCase, async: false

  alias Alethea.Accounts
  alias AletheaWeb.Plugs.ProfessionalAuth

  @password "password12345"
  @remember_cookie "_alethea_remember_me"

  setup do
    initial_restricted = Application.get_env(:alethea, :demo_restricted_access)
    initial_allowed = Application.get_env(:alethea, :demo_allowed_emails)

    on_exit(fn ->
      if initial_restricted == nil do
        Application.delete_env(:alethea, :demo_restricted_access)
      else
        Application.put_env(:alethea, :demo_restricted_access, initial_restricted)
      end

      if initial_allowed == nil do
        Application.delete_env(:alethea, :demo_allowed_emails)
      else
        Application.put_env(:alethea, :demo_allowed_emails, initial_allowed)
      end
    end)

    :ok
  end

  defp create_professional(attrs \\ %{}) do
    email = Map.get(attrs, :email, "doc-#{System.unique_integer()}@example.com")

    {:ok, professional} =
      Accounts.create_professional(%{
        email: email,
        full_name: "Doctor Test",
        password: @password
      })

    professional
  end

  describe "POST /login (admission gating)" do
    test "when restricted and email is unlisted, rejects with invalid credentials error and sets no session or cookie",
         %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["allowed@example.com"])

      professional =
        create_professional(%{email: "unlisted-#{System.unique_integer()}@example.com"})

      conn =
        post(conn, ~p"/login", %{
          "professional" => %{
            "email" => professional.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Correo o contraseña incorrectos."
      refute get_session(conn, :professional_id)
      refute conn.resp_cookies[@remember_cookie]
    end

    test "when restricted and email is listed (case-insensitive), logs in successfully", %{
      conn: conn
    } do
      email = "allowed-#{System.unique_integer()}@example.com"
      professional = create_professional(%{email: email})

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, [String.upcase(email)])

      conn =
        post(conn, ~p"/login", %{
          "professional" => %{
            "email" => email,
            "password" => @password
          }
        })

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, :professional_id) == professional.id
    end
  end

  describe "fetch_current_professional plug (session gating)" do
    test "when restricted and session professional is unlisted, assigns nil without crashing", %{
      conn: conn
    } do
      professional = create_professional()

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["allowed@example.com"])

      conn =
        conn
        |> Plug.Test.init_test_session(%{professional_id: professional.id})
        |> ProfessionalAuth.fetch_current_professional([])

      assert conn.assigns[:current_professional] == nil
      assert get_session(conn, :professional_id) == professional.id
    end

    test "when restricted and session professional is listed, assigns professional", %{conn: conn} do
      professional = create_professional()

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, [professional.email])

      conn =
        conn
        |> Plug.Test.init_test_session(%{professional_id: professional.id})
        |> ProfessionalAuth.fetch_current_professional([])

      assert conn.assigns[:current_professional].id == professional.id
    end
  end

  describe "on_mount(:mount_current_professional) gating" do
    test "when restricted and professional is unlisted, halts and redirects to /login with error flash" do
      professional = create_professional()

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["someone-else@example.com"])

      socket = %Phoenix.LiveView.Socket{
        endpoint: AletheaWeb.Endpoint,
        router: AletheaWeb.Router
      }

      assert {:halt, redirected_socket} =
               ProfessionalAuth.on_mount(
                 :mount_current_professional,
                 %{},
                 %{"professional_id" => professional.id},
                 socket
               )

      assert {:redirect, opts} = redirected_socket.redirected
      assert opts.to == "/login"
    end
  end

  describe "remember cookie gating" do
    test "when restricted and verified professional is unlisted, deletes cookie, invalidates token, assigns nil",
         %{conn: conn} do
      professional = create_professional()
      {:ok, token} = Accounts.generate_remember_token(professional)

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["someone-else@example.com"])

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Test.put_req_cookie(@remember_cookie, token)
        |> ProfessionalAuth.fetch_current_professional([])

      assert conn.assigns[:current_professional] == nil
      refute get_session(conn, :professional_id)

      # Cookie is deleted
      assert deleted_cookie = conn.resp_cookies[@remember_cookie]
      assert deleted_cookie.max_age == 0

      # Token in database is invalidated
      reloaded = Accounts.get_professional!(professional.id)
      assert reloaded.remember_token_hash == nil
      assert reloaded.remember_token_expires_at == nil
    end

    test "when restricted and verified professional is listed, admits professional", %{conn: conn} do
      professional = create_professional()
      {:ok, token} = Accounts.generate_remember_token(professional)

      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, [professional.email])

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Test.put_req_cookie(@remember_cookie, token)
        |> ProfessionalAuth.fetch_current_professional([])

      assert conn.assigns[:current_professional].id == professional.id
      assert get_session(conn, :professional_id) == professional.id
    end
  end
end
