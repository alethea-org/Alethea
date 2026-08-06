defmodule AletheaWeb.PageController do
  use AletheaWeb, :controller

  def home(conn, params) do
    if conn.assigns[:current_professional] do
      redirect(conn, to: "/dashboard")
    else
      # PROTOTYPE (#116) — layout variant selector; remove with PagePrototypeVariants.
      render(conn, :home, prototype_variant: params["variant"] || "actual")
    end
  end
end
