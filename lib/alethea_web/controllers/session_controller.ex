defmodule AletheaWeb.SessionController do
  use AletheaWeb, :controller

  alias Alethea.Accounts

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"professional" => %{"email" => email, "password" => password}}) do
    case Accounts.authenticate_professional(email, password) do
      {:ok, professional} ->
        return_to = get_session(conn, :return_to) || "/dashboard"

        conn
        |> configure_session(renew: true)
        |> put_session(:professional_id, professional.id)
        |> delete_session(:return_to)
        |> redirect(to: return_to)

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Correo o contraseña incorrectos.")
        |> redirect(to: "/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:professional_id)
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  # Called from LiveView to set session (LiveView can't set session directly)
  def set_session(conn, %{"professional_id" => professional_id}) do
    conn
    |> configure_session(renew: true)
    |> put_session(:professional_id, String.to_integer(professional_id))
    |> redirect(to: "/dashboard")
  end
end
