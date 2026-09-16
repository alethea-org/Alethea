defmodule AletheaWeb.RouterTest do
  @moduledoc """
  Route-level specs for retired surfaces.

  #234b retires `PatientLive.ClinicalSearch` (D5): the grounded
  consultation chat is the single primary clinical-record surface
  (D1/#221), so the ranked-list search route must no longer resolve and
  its module must no longer exist.

  The retired path is written as a plain string on purpose — a `~p`
  sigil would not compile once the route is gone. And the retirement
  shows up as a rendered 404 rather than a raised
  `Phoenix.Router.NoRouteError`, because this endpoint has `render_errors`
  configured: the router's error is translated into a response. The
  control test below is what makes that 404 meaningful — a route that
  still exists answers an unauthenticated request with a redirect, so
  only a genuinely absent route yields 404.
  """
  use AletheaWeb.ConnCase

  describe "retired clinical-search route (#234b)" do
    test "the ranked-list search path no longer resolves to any route", %{conn: conn} do
      path = "/patients/#{Ecto.UUID.generate()}/clinical-search"

      assert get(conn, path).status == 404
    end

    test "control: a route that still exists redirects instead of 404ing", %{conn: conn} do
      path = "/patients/#{Ecto.UUID.generate()}/consultation"

      assert get(conn, path).status == 302
    end

    test "the ClinicalSearch LiveView module no longer exists" do
      refute Code.ensure_loaded?(AletheaWeb.PatientLive.ClinicalSearch)
    end
  end
end
