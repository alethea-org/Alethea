defmodule AletheaWeb.Plugs.ProfessionalAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Alethea.Accounts

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
