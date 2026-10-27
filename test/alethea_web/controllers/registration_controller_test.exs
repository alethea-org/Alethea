defmodule AletheaWeb.RegistrationControllerTest do
  use AletheaWeb.ConnCase, async: false

  alias Alethea.Accounts.Professional
  alias Alethea.Repo

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
      assert Repo.get_by(Professional, email: email)
    end
  end
end
