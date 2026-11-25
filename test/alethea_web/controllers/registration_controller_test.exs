defmodule AletheaWeb.RegistrationControllerTest do
  use AletheaWeb.ConnCase, async: false

  alias Alethea.Accounts.Professional
  alias Alethea.Repo

  import Ecto.Query, only: [from: 2]

  @password "password12345"

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

  describe "GET /register" do
    test "when unrestricted, shows the registration form", %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, false)

      assert conn |> get(~p"/register") |> html_response(200) =~ ~s(id="registration-form")
    end

    test "when restricted, sends visitors to the launch waitlist", %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["tester@example.com"])

      assert conn |> get(~p"/register") |> redirected_to() == "/#lista-de-espera"
    end

    test "when restricted, the invitation link still shows the form", %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["tester@example.com"])

      assert conn |> get(~p"/register?invitacion=1") |> html_response(200) =~
               ~s(id="registration-form")
    end
  end

  describe "POST /register" do
    test "when unrestricted, creates professional and redirects to /login", %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, false)
      email = "open-#{System.unique_integer()}@example.com"

      params = %{
        "email" => email,
        "full_name" => "Open Reg Doc",
        "password" => @password
      }

      conn = post(conn, ~p"/register", professional: params)

      assert redirected_to(conn) == ~p"/login"
      assert Repo.get_by(Professional, email: email)
    end

    test "when restricted and email is unlisted, rejects with changeset error and does not create record",
         %{conn: conn} do
      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["allowed@example.com"])
      email = "unlisted-#{System.unique_integer()}@example.com"

      params = %{
        "email" => email,
        "full_name" => "Unlisted Doc",
        "password" => @password
      }

      conn = post(conn, ~p"/register", professional: params)

      assert html_response(conn, 200) =~ "no autorizado"
      refute Repo.get_by(Professional, email: email)
    end

    test "when restricted and email is listed (case-insensitive), creates professional", %{
      conn: conn
    } do
      Application.put_env(:alethea, :demo_restricted_access, true)
      email = "Allowed-Doc-#{System.unique_integer()}@Example.com"
      Application.put_env(:alethea, :demo_allowed_emails, [String.downcase(email)])

      params = %{
        "email" => email,
        "full_name" => "Allowed Doc",
        "password" => @password
      }

      conn = post(conn, ~p"/register", professional: params)

      assert redirected_to(conn) == ~p"/login"
      # Stored in canonical form (S3, security-audit-run-1).
      assert Repo.get_by(Professional, email: String.downcase(email))
    end

    test "a case variant of an existing email is rejected as taken and creates no row", %{
      conn: conn
    } do
      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, ["admin@example.org"])

      {:ok, _admin} =
        Alethea.Accounts.create_professional(%{
          "email" => "admin@example.org",
          "full_name" => "Real Admin",
          "password" => @password
        })

      count_before = Repo.aggregate(Professional, :count)

      params = %{
        "email" => "ADMIN@example.org",
        "full_name" => "Impostor",
        "password" => "impostor-password1"
      }

      conn = post(conn, ~p"/register", professional: params)

      assert html_response(conn, 200) =~ "has already been taken"
      assert Repo.aggregate(Professional, :count) == count_before

      assert [%Professional{full_name: "Real Admin"}] =
               Repo.all(from p in Professional, where: p.email == "admin@example.org")
    end
  end
end
