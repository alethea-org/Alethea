defmodule AletheaWeb.WhatsappWebhookControllerTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  @app_secret "test_app_secret"

  setup do
    # Configurar el app_secret para el test
    original_config = Application.get_env(:alethea, :whatsapp)

    Application.put_env(
      :alethea,
      :whatsapp,
      Keyword.put(original_config, :app_secret, @app_secret)
    )

    on_exit(fn ->
      Application.put_env(:alethea, :whatsapp, original_config)
    end)

    :ok
  end

  describe "GET /webhooks/whatsapp" do
    test "verificación exitosa con token correcto", %{conn: conn} do
      challenge = "123456789"
      token = Application.get_env(:alethea, :whatsapp)[:verify_token] || "alethea_verify_token"

      conn =
        get(conn, ~p"/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => token,
          "hub.challenge" => challenge
        })

      assert response(conn, 200) == challenge
    end

    test "error 403 con token incorrecto", %{conn: conn} do
      conn =
        get(conn, ~p"/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong_token",
          "hub.challenge" => "123"
        })

      assert response(conn, 403) == "Forbidden"
    end
  end

  describe "POST /webhooks/whatsapp" do
    @valid_payload %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{
                    "from" => "56912345678",
                    "id" => "wamid.ID",
                    "text" => %{"body" => "Hola"}
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    test "recibe mensaje y encola job cuando la firma es válida", %{conn: conn} do
      body = Jason.encode!(@valid_payload)

      signature =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, @app_secret, body) |> Base.encode16(case: :lower))

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"

      # Verificar que se encoló el job
      assert_enqueued(worker: AletheaJobs.ProcessMessageWorker)
    end

    test "error 403 cuando la firma es inválida", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-hub-signature-256", "sha256=invalid_hash")
        |> post(~p"/webhooks/whatsapp", @valid_payload)

      assert response(conn, 403) == "Forbidden"
    end

    test "error 403 cuando no hay header de firma", %{conn: conn} do
      conn = post(conn, ~p"/webhooks/whatsapp", @valid_payload)
      assert response(conn, 403) == "Forbidden"
    end
  end
end
