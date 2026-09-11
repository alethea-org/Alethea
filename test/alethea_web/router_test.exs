defmodule AletheaWeb.RouterTest do
  @moduledoc """
  Router-level retirement checks (#234b, sdd/grounded-clinical-chat-initial,
  GitHub #223, D5). `/clinical-search` is a hard cutover — the route no
  longer exists and `PatientLive.ClinicalSearch` no longer compiles into
  the app, not merely unreachable via navigation.
  """
  use AletheaWeb.ConnCase

  test "the retired clinical-search route no longer resolves" do
    fake_id = Ecto.UUID.generate()
    conn = get(build_conn(), "/patients/#{fake_id}/clinical-search")

    assert conn.status == 404
    refute conn.resp_body =~ "Búsqueda clínica"
  end

  test "PatientLive.ClinicalSearch no longer exists" do
    refute Code.ensure_loaded?(AletheaWeb.PatientLive.ClinicalSearch)
  end
end
