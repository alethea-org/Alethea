defmodule AletheaWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.

  `404` and `500` render the editorial error pages in
  `error_html/`. Every other status falls back to the plain status
  message, so an unusual code never depends on a template existing.
  """
  use AletheaWeb, :html

  embed_templates("error_html/*")

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
