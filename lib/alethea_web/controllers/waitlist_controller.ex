defmodule AletheaWeb.WaitlistController do
  @moduledoc """
  Waitlist sign-up from the public landing (`POST /waitlist`).

  `website` is a honeypot: people never see it, bots fill it. A filled
  honeypot gets the same success response and nothing is stored.
  """
  use AletheaWeb, :controller

  alias Alethea.Waitlist

  @joined "¡Listo! Te avisamos por email cuando Alethea esté disponible."

  def create(conn, %{"waitlist" => %{"website" => trap}}) when trap != "" do
    joined(conn)
  end

  def create(conn, %{"waitlist" => params}) do
    case Waitlist.join(Map.take(params, ["name", "email"])) do
      :ok ->
        joined(conn)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(AletheaWeb.PageHTML)
        |> render(:home, waitlist_form: Phoenix.Component.to_form(changeset, as: :waitlist))
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/#lista-de-espera")

  defp joined(conn) do
    conn
    |> put_flash(:waitlist, @joined)
    |> redirect(to: ~p"/#lista-de-espera")
  end
end
