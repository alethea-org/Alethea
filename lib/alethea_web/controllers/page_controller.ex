defmodule AletheaWeb.PageController do
  use AletheaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
