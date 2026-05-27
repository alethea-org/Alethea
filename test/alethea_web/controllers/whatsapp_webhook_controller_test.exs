defmodule AletheaWeb.WhatsappWebhookControllerTest do
  use AletheaWeb.ConnCase, async: true
  import Oban.Testing

  @app_secret "test_secret"

  setup do
    Application.put_env(:alethea, :whatsapp, [app_secret: @app_secret, verify_token: "test_token"])
    on_exit(fn -> Application.delete_env(:alethea, :whatsapp) end)
    :ok
  end

  describe "GET /webhooks/whatsapp" do
    test "responde con el challenge cuando el token es válido", %{conn: conn} do
      conn = get(conn, ~p"/webhooks/whatsapp", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "test_token",
        "hub.challenge" => "123456"
      })

      assert response(conn, 200) == "123456"
    end

    test "responde 403 cuando el token es inválido", %{conn: conn} do
      conn = get(conn, ~p"/webhooks/whatsapp", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "wrong",
        "hub.challenge" => "123456"
      })

      assert response(conn, 403) == "Forbidden"
    end
  end

  describe "POST /webhooks/whatsapp" do
    test "encola un ProcessMessageWorker cuando la firma es válida", %{conn: conn} do
      body = Jason.encode!(%{
        "entry" => [%{
          "changes" => [%{
            "value" => %{
              "messages" => [%{
                "from" => "56912345678",
                "text" => %{"body" => "ACEPTO"},
                "id" => "msg_123"
              }]
            }
          }]
        }]
      })

      signature = "sha256=" <> (:crypto.mac(:hmac, :sha256, @app_secret, body) |> Base.encode16(case: :lower))

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"

      # Usar el Repo explícitamente para Oban en el test
      assert_enqueued repo: Alethea.Repo, worker: AletheaJobs.ProcessMessageWorker, args: %{
        "from" => "56912345678",
        "text" => "ACEPTO",
        "whatsapp_message_id" => "msg_123"
      }
    end

    test "responde 403 cuando la firma es inválida", %{conn: conn} do
      body = "{}"
      signature = "sha256=invalid"

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/whatsapp", body)

      assert response(conn, 403) == "Forbidden"
    end
  end
end
