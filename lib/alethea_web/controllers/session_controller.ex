defmodule AletheaWeb.SessionController do
  use AletheaWeb, :controller

  alias Alethea.Accounts

  require Logger

  @remember_cookie "_alethea_remember_me"
  @remember_cookie_options [http_only: true, secure: true, same_site: "Lax", path: "/"]

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"professional" => %{"email" => email, "password" => password} = params}) do
    case Accounts.authenticate_professional(email, password) do
      {:ok, professional} ->
        return_to = get_session(conn, :return_to) || "/dashboard"
        remember_me? = remember_me?(params)

        conn
        |> configure_session(renew: true)
        |> put_session(:professional_id, professional.id)
        |> delete_session(:return_to)
        |> maybe_put_remember_cookie(professional, remember_me?)
        |> redirect(to: return_to)

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Correo o contraseña incorrectos.")
        |> redirect(to: "/login")
    end
  end

  def delete(conn, _params) do
    professional_id =
      get_session(conn, :professional_id) ||
        (conn.assigns[:current_professional] && conn.assigns.current_professional.id)

    if professional_id do
      Accounts.invalidate_remember_token(professional_id)
    end

    conn
    |> delete_remember_cookie()
    |> delete_session(:professional_id)
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  # Called from LiveView to set session (LiveView can't set session directly)
  def set_session(conn, %{"professional_id" => professional_id}) do
    conn
    |> configure_session(renew: true)
    |> put_session(:professional_id, professional_id)
    |> redirect(to: "/dashboard")
  end

  defp maybe_put_remember_cookie(conn, professional, true) do
    case Accounts.generate_remember_token(professional) do
      {:ok, token} ->
        put_remember_cookie(conn, token)

      {:error, reason} ->
        Logger.error(
          "Failed to generate remember token for professional #{professional.id}: #{inspect(reason)}"
        )

        conn
    end
  end

  defp maybe_put_remember_cookie(conn, _professional, false) do
    delete_remember_cookie(conn)
  end

  defp remember_me?(%{"remember_me" => value}), do: value in ["true", "on", "1", true]
  defp remember_me?(%{remember_me: value}), do: value in ["true", "on", "1", true]
  defp remember_me?(_params), do: false

  defp put_remember_cookie(conn, token) do
    put_resp_cookie(
      conn,
      @remember_cookie,
      token,
      Keyword.put(@remember_cookie_options, :max_age, Accounts.remember_token_max_age())
    )
  end

  defp delete_remember_cookie(conn) do
    delete_resp_cookie(conn, @remember_cookie, @remember_cookie_options)
  end
end
