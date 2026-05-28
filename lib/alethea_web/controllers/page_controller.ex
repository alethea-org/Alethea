defmodule AletheaWeb.PageController do
  use AletheaWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_professional] do
      redirect(conn, to: "/dashboard")
    else
      render(conn, :home)
    end
  end
end
