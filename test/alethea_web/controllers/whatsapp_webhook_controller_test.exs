defmodule AletheaWeb.WhatsappWebhookControllerTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  @app_secret "test_app_secret"

  setup do
    original_config = Application.get_env(:alethea, :whatsapp, [])

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

  describe "POST /webhooks/whatsapp" do
    @valid_payload %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{
                    "from" => "+56955555555",
                    "id" => "wamid.999",
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
      assert_enqueued(worker: AletheaJobs.ProcessMessageWorker)
    end

    test "error 403 cuando la firma es inválida", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-hub-signature-256", "sha256=invalid_hash")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/whatsapp", @valid_payload)

      assert response(conn, 403) == "Forbidden"
      refute_enqueued(worker: AletheaJobs.ProcessMessageWorker)
    end

    test "error 403 cuando no hay header de firma", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/whatsapp", @valid_payload)

      assert response(conn, 403) == "Forbidden"
      refute_enqueued(worker: AletheaJobs.ProcessMessageWorker)
    end
  end
end
