defmodule AletheaWeb.OpenApiSpecPlug do
  @moduledoc """
  Controller for serving the OpenAPI specification as JSON.
  """
  use AletheaWeb, :controller

  def show(conn, _params) do
    spec =
      AletheaWeb.ApiSpec.spec()
      |> OpenApiSpex.resolve_schema_modules()
      |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, spec)
  end
end
