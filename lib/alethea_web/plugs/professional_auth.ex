defmodule AletheaWeb.Plugs.ProfessionalAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Alethea.Accounts
  alias Alethea.Encryption.ProfessionalKek

  require Logger

  @remember_cookie "_alethea_remember_me"
  @remember_cookie_options [http_only: true, secure: true, same_site: "Lax", path: "/"]

  def on_mount(:mount_current_professional, _params, session, socket) do
    case session["professional_id"] do
      nil ->
        {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}

      professional_id ->
        try do
          professional = Accounts.get_professional!(professional_id)

          # NEW: Verify KEK exists for this professional
          case ProfessionalKek.kek_exists?(professional_id) do
            {:ok, _key_id} ->
              # KEK ownership verified, now load it
              case Accounts.load_professional_kek(professional) do
                {:ok, kek} ->
                  # NEW: Log successful KEK access
                  log_kek_access(professional_id, :success)

                  {:cont,
                   socket
                   |> Phoenix.Component.assign(:current_professional, professional)
                   |> Phoenix.Component.assign(:professional_kek, kek)}

                {:error, _reason} ->
                  # KEK exists but couldn't be loaded - this shouldn't happen
                  log_kek_access(professional_id, :load_failed)

                  redirect_with_error(
                    socket,
                    "Sesión inválida. Por favor, iniciá sesión nuevamente."
                  )
              end

            {:error, :not_found} ->
              # No KEK for this professional - session is invalid
              log_kek_access(professional_id, :not_found)
              redirect_with_error(socket, "Sesión inválida. Por favor, iniciá sesión nuevamente.")
          end
        rescue
          _e in Ecto.NoResultsError ->
            {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}

          _e ->
            Logger.error("Unexpected error in on_mount: #{inspect(__STACKTRACE__)}")
            {:cont, Phoenix.Component.assign(socket, :current_professional, nil)}
        end
    end
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

  def call(conn, :require_authenticated_professional),
    do: require_authenticated_professional(conn, [])

  def call(conn, :redirect_if_authenticated), do: redirect_if_authenticated(conn, [])

  def fetch_current_professional(conn, _opts) do
    case get_session(conn, :professional_id) do
      nil -> fetch_current_professional_from_remember_cookie(conn)
      professional_id -> fetch_current_professional_from_session(conn, professional_id)
    end
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

  # NEW private functions

  defp fetch_current_professional_from_session(conn, professional_id) do
    professional = Accounts.get_professional!(professional_id)

    assign(conn, :current_professional, professional)
  rescue
    Ecto.NoResultsError -> assign(conn, :current_professional, nil)
  end

  defp fetch_current_professional_from_remember_cookie(conn) do
    conn = fetch_cookies(conn)

    case Map.get(conn.req_cookies, @remember_cookie) do
      nil ->
        assign(conn, :current_professional, nil)

      token ->
        case Accounts.verify_remember_token(token) do
          {:ok, professional, rotated_token} ->
            conn
            |> configure_session(renew: true)
            |> put_session(:professional_id, professional.id)
            |> put_remember_cookie(rotated_token)
            |> assign(:current_professional, professional)

          {:error, _reason} ->
            conn
            |> delete_remember_cookie()
            |> assign(:current_professional, nil)
        end
    end
  end

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

  defp log_kek_access(professional_id, result) do
    try do
      Accounts.log_action(%{
        action: "KEK_ACCESS",
        professional_id: professional_id,
        resource_type: "KEK",
        resource_id: nil,
        details: %{result: result}
      })
    rescue
      # Don't fail auth if audit fails
      _ -> :ok
    end
  end

  defp redirect_with_error(socket, message) do
    {:halt, Phoenix.LiveView.redirect(socket, to: "/login", flash: %{error: message})}
  end
end
