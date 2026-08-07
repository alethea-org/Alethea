defmodule AletheaWeb.PageController do
  use AletheaWeb, :controller

  def home(conn, params) do
    if conn.assigns[:current_professional] do
      redirect(conn, to: "/dashboard")
    else
      # PROTOTYPE (#116) — layout variant selector; remove with PagePrototypeVariants.
      render(conn, :home,
        prototype_variant: params["variant"] || "actual",
        theme: prototype_theme(params["theme"])
      )
    end
  end

  # PROTOTYPE (#116) — the theme lands in a DOM class, so only allow known
  # values instead of interpolating whatever arrives in the query string.
  defp prototype_theme(theme) when theme in ["warm", "editorial"], do: theme
  defp prototype_theme(_), do: "default"
end
