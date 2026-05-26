defmodule AletheaWeb.Plugs.ProfessionalAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Alethea.Accounts

  def on_mount(:mount_current_professional, _params, session, socket) do
    case session["professional_id"] do
      nil ->
        {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}

      professional_id ->
        professional = Accounts.get_professional!(professional_id)

        # Cargar la KEK en memoria (solo para el proceso LiveView)
        {:ok, kek} = Accounts.load_professional_kek(professional)

        {:cont,
         socket
         |> Phoenix.Component.assign(:current_professional, professional)
         |> Phoenix.Component.assign(:professional_kek, kek)}
    end
  rescue
    _ -> {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}
  end

  def on_mount(:require_authenticated_professional, _params, _session, socket) do
    if socket.assigns.current_professional do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def init(action)
      when action in [
             :fetch_current_professional,
             :require_authenticated_professional,
             :redirect_if_authenticated
           ],
      do: action

  def call(conn, :fetch_current_professional), do: fetch_current_professional(conn, [])
  def call(conn, :require_authenticated_professional), do: require_authenticated_professional(conn, [])
  def call(conn, :redirect_if_authenticated), do: redirect_if_authenticated(conn, [])

  def fetch_current_professional(conn, _opts) do
    professional_id = get_session(conn, :professional_id)

    professional =
      professional_id && Accounts.get_professional!(professional_id)

    assign(conn, :current_professional, professional)
  rescue
    Ecto.NoResultsError -> assign(conn, :current_professional, nil)
  end

  def require_authenticated_professional(conn, _opts) do
    if conn.assigns[:current_professional] do
      conn
    else
      conn
      |> put_session(:return_to, conn.request_path)
      |> redirect(to: "/login")
      |> halt()
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_professional] do
      conn
      |> redirect(to: "/dashboard")
      |> halt()
    else
      conn
    end
  end
end
