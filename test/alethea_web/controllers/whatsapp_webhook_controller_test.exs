defmodule AletheaWeb.WhatsappWebhookControllerTest do
  use AletheaWeb.ConnCase, async: false
  import Oban.Testing
  import Phoenix.ConnTest
  import AletheaWeb.WhatsappFixtures

  @moduletag :whatsapp

  setup do
    # Clear rate limiter before each test to prevent rate limiting interference
    Alethea.RateLimiter.clear_all()

    old_config = Application.get_env(:alethea, :whatsapp, [])

    new_config =
      Keyword.merge(old_config,
        app_secret: "test_secret",
        verify_token: "test_token"
      )

    Application.put_env(:alethea, :whatsapp, new_config)

    on_exit(fn ->
      Application.put_env(:alethea, :whatsapp, old_config)
      # Also clear rate limiter after test
      Alethea.RateLimiter.clear_all()
    end)

    :ok
  end

  describe "GET /webhooks/whatsapp" do
    test "responde con el challenge cuando el token es válido", %{conn: conn} do
      conn =
        get(conn, "/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "test_token",
          "hub.challenge" => "123456"
        })

      assert response(conn, 200) == "123456"
    end

    test "responde 403 cuando el token es inválido", %{conn: conn} do
      conn =
        get(conn, "/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong",
          "hub.challenge" => "123456"
        })

      assert response(conn, 403) == "Forbidden"
    end

    test "responde 400 cuando faltan parámetros", %{conn: conn} do
      conn = get(conn, "/webhooks/whatsapp", %{})

      assert response(conn, 400) == "Bad Request"
    end
  end

  describe "POST /webhooks/whatsapp - signature verification" do
    test "encola un ProcessMessageWorker cuando la firma es válida (usando fixture)",
         %{conn: conn} do
      {:ok, payload} = text_message()
      body = Jason.encode!(payload)

      signature = valid_signature(body)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"

      assert_enqueued(
        repo: Alethea.Repo,
        worker: AletheaJobs.ProcessMessageWorker,
        args: %{
          "from" => "56912345678",
          "text" => "Hola, necesito ayuda con mi tratamiento",
          "whatsapp_message_id" => "wamid.HBgLNjkxMjM0NTY3OA=="
        }
      )
    end

    test "responde 403 cuando la firma es inválida", %{conn: conn} do
      body = Jason.encode!(%{})

      conn =
        conn
        |> put_req_header("x-hub-signature-256", invalid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 403) == "Forbidden"
    end

    test "responde 403 cuando la firma usa clave incorrecta", %{conn: conn} do
      {:ok, payload} = text_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", wrong_secret_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 403) == "Forbidden"
    end

    test "responde 403 cuando falta header de firma", %{conn: conn} do
      {:ok, payload} = text_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 403) == "Forbidden"
    end

    test "responde 403 cuando signature header está vacío", %{conn: conn} do
      {:ok, payload} = text_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", "")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 403) == "Forbidden"
    end
  end

  describe "POST /webhooks/whatsapp - message types" do
    test "procesa mensaje de texto", %{conn: conn} do
      {:ok, payload} = text_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"

      assert_enqueued(
        repo: Alethea.Repo,
        worker: AletheaJobs.ProcessMessageWorker
      )
    end

    test "responde 200 para mensaje de imagen (no es text message type)",
         %{conn: conn} do
      {:ok, payload} = image_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      # El controller responde OK pero no encola job porque no es type=text
      assert response(conn, 200) == "OK"

      refute_enqueued(
        repo: Alethea.Repo,
        worker: AletheaJobs.ProcessMessageWorker
      )
    end

    test "responde 200 para mensaje de audio", %{conn: conn} do
      {:ok, payload} = audio_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"
    end

    test "responde 200 para mensaje de video", %{conn: conn} do
      {:ok, payload} = video_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"
    end

    test "responde 200 para mensaje de documento", %{conn: conn} do
      {:ok, payload} = document_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"
    end

    test "responde 200 para mensaje de ubicación", %{conn: conn} do
      {:ok, payload} = location_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"
    end

    test "responde 200 para mensaje de contactos", %{conn: conn} do
      {:ok, payload} = contacts_message()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      assert response(conn, 200) == "OK"
    end

    test "responde 200 para status update (no es mensaje)", %{conn: conn} do
      {:ok, payload} = status_update()
      body = Jason.encode!(payload)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", valid_signature(body))
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/whatsapp", body)

      # Status updates no encolan ProcessMessageWorker
      assert response(conn, 200) == "OK"

      refute_enqueued(
        repo: Alethea.Repo,
        worker: AletheaJobs.ProcessMessageWorker
      )
    end
  end

  describe "POST /webhooks/whatsapp - rate limiting" do
    test "responde 429 cuando se supera el límite de requests" do
      # Clear rate limiter
      Alethea.RateLimiter.clear_all()

      {:ok, payload} = text_message()
      body = Jason.encode!(payload)

      # Make 12 requests rapidly
      results =
        for i <- 1..12 do
          conn = build_conn()

          resp =
            conn
            |> put_req_header("x-hub-signature-256", valid_signature(body))
            |> put_req_header("content-type", "application/json")
            |> post("/webhooks/whatsapp", body)

          %{index: i, status: resp.status}
        end

      # Count statuses
      count_200 = Enum.count(results, &(&1.status == 200))
      count_429 = Enum.count(results, &(&1.status == 429))

      # After 10 requests, rate limiting should kick in
      assert count_429 >= 1,
             "Expected at least 1 rate-limited response. Got #{count_429} 429s and #{count_200} 200s. Results: #{inspect(results, pretty: true)}"
    end
  end

  describe "fixture validation" do
    test "text_message fixture tiene estructura válida" do
      {:ok, payload} = text_message()

      assert is_map(payload)
      assert payload["object"] == "whatsapp_business_account"
      assert get_in(payload, ["entry", Access.at(0), "changes"]) != nil

      messages =
        get_in(payload, ["entry", Access.at(0), "changes", Access.at(0), "value", "messages"])

      assert messages != nil
      assert length(messages) > 0

      first_msg = hd(messages)
      assert first_msg["from"] == "56912345678"
      assert first_msg["type"] == "text"
      assert get_in(first_msg, ["text", "body"]) != nil
    end

    test "image_message fixture tiene estructura válida" do
      {:ok, payload} = image_message()

      messages =
        get_in(payload, ["entry", Access.at(0), "changes", Access.at(0), "value", "messages"])

      first_msg = hd(messages)
      assert first_msg["type"] == "image"
      assert first_msg["image"]["id"] == "IMAGE_ID"
    end

    test "status_update fixture tiene estructura válida" do
      {:ok, payload} = status_update()

      statuses =
        get_in(payload, ["entry", Access.at(0), "changes", Access.at(0), "value", "statuses"])

      assert statuses != nil
      assert hd(statuses)["status"] == "delivered"
    end
  end
end
