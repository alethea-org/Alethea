defmodule AletheaWeb.SessionController do
  use AletheaWeb, :controller

  alias Alethea.Accounts

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
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end
end
