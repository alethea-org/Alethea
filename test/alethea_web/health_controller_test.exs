defmodule AletheaWeb.HealthControllerTest do
  use AletheaWeb.ConnCase, async: false

  describe "GET /health (liveness)" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/health")

      assert %{
               "status" => "ok"
             } = json_response(conn, 200)
    end
  end

  describe "GET /health/ready (readiness)" do
    test "returns 200 when all services are healthy", %{conn: conn} do
      conn = get(conn, "/health/ready")
      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["checks"]["database"] == "ok"
      assert response["checks"]["redis"] == "ok"
    end
  end
end