defmodule AletheaWeb.SessionHTML do
  @moduledoc """
  Templates rendered by SessionController (login page).
  """
  use AletheaWeb, :html

  embed_templates "session_html/*"
end
