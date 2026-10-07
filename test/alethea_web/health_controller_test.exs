defmodule AletheaWeb.HealthControllerTest do
  use AletheaWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # A connection error as Postgrex reports it: the message can carry the
  # database host and credentials, so it must never reach the response body.
  @secret "postgres://alethea:s3cret-pass@db.internal:5432/alethea_prod"

  defp put_health_checks(overrides) do
    previous = Application.get_env(:alethea, :health_checks)
    Application.put_env(:alethea, :health_checks, overrides)

    on_exit(fn ->
      if previous do
        Application.put_env(:alethea, :health_checks, previous)
      else
        Application.delete_env(:alethea, :health_checks)
      end
    end)
  end

  defp database_error, do: {:error, %DBConnection.ConnectionError{message: @secret}}

  describe "GET /health (liveness)" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/health")

      assert %{
               "status" => "ok"
             } = json_response(conn, 200)
    end

    test "stays 200 when every dependency is down", %{conn: conn} do
      put_health_checks(query: fn _sql -> raise "database is down" end, oban_name: NoSuchOban)

      assert json_response(get(conn, "/health"), 200) == %{"status" => "ok"}
    end
  end

  describe "GET /health/ready (readiness)" do
    test "returns 200 when all services are healthy", %{conn: conn} do
      conn = get(conn, "/health/ready")
      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["checks"]["database"] == "ok"
      assert response["checks"]["oban"] == "ok"
    end

    test "returns 503 when the database query returns an error tuple", %{conn: conn} do
      put_health_checks(query: fn _sql -> database_error() end)

      response = conn |> get("/health/ready") |> json_response(503)

      assert response["status"] == "unavailable"
      assert response["checks"]["database"] == "error"
    end

    test "returns 503 when the database query raises", %{conn: conn} do
      put_health_checks(query: fn _sql -> raise DBConnection.ConnectionError, @secret end)

      response = conn |> get("/health/ready") |> json_response(503)

      assert response["status"] == "unavailable"
      assert response["checks"]["database"] == "error"
    end

    test "returns 503 when the database query exits", %{conn: conn} do
      put_health_checks(query: fn _sql -> exit(:noproc) end)

      response = conn |> get("/health/ready") |> json_response(503)

      assert response["checks"]["database"] == "error"
    end

    test "returns 503 when the Oban instance is not running", %{conn: conn} do
      put_health_checks(oban_name: NoSuchOban)

      response = conn |> get("/health/ready") |> json_response(503)

      assert response["status"] == "unavailable"
      assert response["checks"] == %{"database" => "ok", "oban" => "error"}
    end

    test "returns 503 when the Oban jobs table cannot be queried", %{conn: conn} do
      put_health_checks(
        query: fn
          "SELECT 1" -> {:ok, %{rows: [[1]]}}
          _oban_jobs_sql -> database_error()
        end
      )

      response = conn |> get("/health/ready") |> json_response(503)

      assert response["status"] == "unavailable"
      assert response["checks"] == %{"database" => "ok", "oban" => "error"}
    end

    test "never exposes the failure reason in the body or the logs", %{conn: conn} do
      put_health_checks(query: fn _sql -> database_error() end)

      {body, log} =
        with_log(fn -> conn |> get("/health/ready") |> response(503) end)

      refute body =~ "s3cret-pass"
      refute body =~ "db.internal"
      refute log =~ "s3cret-pass"

      assert Jason.decode!(body) == %{
               "status" => "unavailable",
               "checks" => %{"database" => "error", "oban" => "error"}
             }
    end
  end

  describe "force_ssl in production" do
    setup do
      force_ssl =
        "config/prod.exs"
        |> Config.Reader.read!(env: :prod)
        |> get_in([:alethea, AletheaWeb.Endpoint, :force_ssl])

      %{ssl: Plug.SSL.init(Keyword.put(force_ssl, :host, "alethea.example"))}
    end

    defp plain_http(path), do: %{Plug.Test.conn(:get, path) | host: "10.0.0.7"}

    test "does not redirect the platform HTTP checks", %{ssl: ssl} do
      for path <- ["/health", "/health/ready"] do
        conn = Plug.SSL.call(plain_http(path), ssl)

        refute conn.halted, "#{path} was redirected"
      end
    end

    test "still redirects every other plain HTTP request", %{ssl: ssl} do
      for path <- ["/", "/login", "/health/other", "/healthz"] do
        redirected = Plug.SSL.call(plain_http(path), ssl)

        assert %Plug.Conn{halted: true, status: 301} = redirected

        assert Plug.Conn.get_resp_header(redirected, "location") == [
                 "https://alethea.example#{path}"
               ]
      end
    end

    test "keeps HSTS on requests forwarded as HTTPS", %{ssl: ssl} do
      conn =
        "/"
        |> plain_http()
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Plug.SSL.call(ssl)

      refute conn.halted
      assert [hsts] = Plug.Conn.get_resp_header(conn, "strict-transport-security")
      assert hsts =~ "max-age="
    end
  end

  test "legacy model test endpoint is not exposed", %{conn: conn} do
    conn = get(conn, "/health/test-roberta")
    assert response(conn, 404)
  end
end
