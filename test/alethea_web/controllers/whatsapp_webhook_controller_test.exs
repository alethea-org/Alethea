defmodule AletheaWeb.WhatsappWebhookControllerTest do
  use AletheaWeb.ConnCase, async: true

  import Mox
  import Oban.Testing

  test "firma válida encola job y devuelve 200", %{conn: conn} do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{"from" => "+56955555555", "text" => %{"body" => "Hola"}, "id" => "wamid.999"}
                ]
              }
            }
          ]
        }
      ]
    }

    body = Jason.encode!(payload)
    secret = Application.fetch_env!(:alethea, :whatsapp)[:app_secret]
    signature = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)

    response = post(conn, "/webhooks/whatsapp", body)

    assert response.status == 200
    assert_enqueued(worker: AletheaJobs.ProcessMessageWorker, args: %{"from" => "+56955555555", "text" => "Hola", "whatsapp_message_id" => "wamid.999"})
  end

  test "firma inválida devuelve 403 y no encola job", %{conn: conn} do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{"from" => "+56955555555", "text" => %{"body" => "Hola"}, "id" => "wamid.999"}
                ]
              }
            }
          ]
        }
      ]
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=deadbeef")

    response = post(conn, "/webhooks/whatsapp", Jason.encode!(payload))

    assert response.status == 403
    refute_enqueued(worker: AletheaJobs.ProcessMessageWorker)
  end

  test "sin header de firma devuelve 403", %{conn: conn} do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{"from" => "+56955555555", "text" => %{"body" => "Hola"}, "id" => "wamid.999"}
                ]
              }
            }
          ]
        }
      ]
    }

    conn = put_req_header(conn, "content-type", "application/json")
    response = post(conn, "/webhooks/whatsapp", Jason.encode!(payload))

    assert response.status == 403
    refute_enqueued(worker: AletheaJobs.ProcessMessageWorker)
  end
end
