defmodule Alethea.Telegram.WebhookRegistrationTest do
  @moduledoc """
  `setWebhook` registration verified through `getWebhookInfo` (issue #402).
  Every request goes to a `Req.Test` stub; nothing reaches Telegram. Every
  value below is synthetic.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Alethea.Telegram.WebhookRegistration

  @bot_token "123456:synthetic-registration-token"
  @secret_token "synthetic_registration_secret"
  @webhook_url "https://app.example.test/webhooks/telegram"

  @option_keys [:telegram_webhook_registration_req_options, :telegram_webhook_info_req_options]

  setup do
    previous = Map.new(@option_keys, &{&1, Application.get_env(:alethea, &1)})

    for key <- @option_keys do
      Application.put_env(:alethea, key, plug: {Req.Test, __MODULE__})
    end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:alethea, key)
        {key, value} -> Application.put_env(:alethea, key, value)
      end)
    end)
  end

  describe "register/3" do
    test "sends url, secret_token and allowed_updates, then verifies the registration" do
      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/setWebhook"

        assert json_body(conn) == %{
                 "url" => @webhook_url,
                 "secret_token" => @secret_token,
                 "allowed_updates" => ["message"]
               }

        Req.Test.json(conn, %{"ok" => true, "result" => true, "description" => "Webhook was set"})
      end)

      expect_webhook_info(%{
        "url" => @webhook_url,
        "pending_update_count" => 2,
        "allowed_updates" => ["message"]
      })

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:ok,
                %{
                  status: :registered,
                  webhook_url: @webhook_url,
                  allowed_updates: ["message"],
                  pending_update_count: 2
                }}

      Req.Test.verify!(__MODULE__)
    end

    test "never asks Telegram to drop pending updates" do
      expect_webhook_info(%{"url" => "", "pending_update_count" => 7})

      Req.Test.expect(__MODULE__, fn conn ->
        body = json_body(conn)

        refute Map.has_key?(body, "drop_pending_updates")
        refute conn.query_string =~ "drop_pending_updates"

        Req.Test.json(conn, %{"ok" => true, "result" => true})
      end)

      expect_webhook_info(registered_info(%{"pending_update_count" => 7}))

      assert {:ok, %{pending_update_count: 7}} =
               WebhookRegistration.register(@bot_token, @secret_token, @webhook_url)
    end

    test "re-registers an identical webhook and reports it as already registered" do
      expect_webhook_info(registered_info())

      # The secret is not readable from getWebhookInfo, so the call is still
      # made: it is what carries a rotated secret to Telegram.
      Req.Test.expect(__MODULE__, fn conn ->
        assert json_body(conn)["secret_token"] == @secret_token
        Req.Test.json(conn, %{"ok" => true, "result" => true})
      end)

      expect_webhook_info(registered_info())

      assert {:ok, %{status: :already_registered, webhook_url: @webhook_url}} =
               WebhookRegistration.register(@bot_token, @secret_token, @webhook_url)

      Req.Test.verify!(__MODULE__)
    end

    test "a different URL or update list counts as a new registration" do
      for before <- [
            %{"url" => "https://old.example.test/webhooks/telegram", "pending_update_count" => 0},
            %{"url" => @webhook_url, "pending_update_count" => 0},
            registered_info(%{"allowed_updates" => ["message", "callback_query"]})
          ] do
        expect_webhook_info(before)
        Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"ok" => true, "result" => true}))
        expect_webhook_info(registered_info())

        assert {:ok, %{status: :registered}} =
                 WebhookRegistration.register(@bot_token, @secret_token, @webhook_url)
      end
    end

    test "returns Telegram's ok: false description as a tagged error" do
      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: bad webhook: HTTPS url must be provided"
        })
      end)

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:error, {:telegram, 400, "Bad Request: bad webhook: HTTPS url must be provided"}}

      # No verification request follows a rejected registration.
      Req.Test.verify!(__MODULE__)
    end

    test "returns HTTP 429 with retry_after as a tagged error, without retrying" do
      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 429,
          "description" => "Too Many Requests: retry after 17",
          "parameters" => %{"retry_after" => 17}
        })
      end)

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:error, {:rate_limited, 17}}

      Req.Test.verify!(__MODULE__)
    end

    test "returns a transport failure as a tagged error" do
      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:error, {:transport, :timeout}}

      Req.Test.verify!(__MODULE__)
    end

    test "does not call setWebhook when the current state cannot be read" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"ok" => false, "error_code" => 401, "description" => "Unauthorized"})
      end)

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:error, {:webhook_info, :unauthorized}}

      Req.Test.verify!(__MODULE__)
    end

    test "a verification mismatch is an error" do
      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"ok" => true, "result" => true}))

      expect_webhook_info(%{
        "url" => "https://other.example.test/webhooks/telegram",
        "pending_update_count" => 0,
        "allowed_updates" => ["message"]
      })

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:error, {:verification_failed, :url_mismatch}}

      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"ok" => true, "result" => true}))
      expect_webhook_info(%{"url" => @webhook_url, "pending_update_count" => 0})

      assert WebhookRegistration.register(@bot_token, @secret_token, @webhook_url) ==
               {:error, {:verification_failed, :allowed_updates_mismatch}}
    end

    test "rejects a webhook URL that is not HTTPS before any request" do
      for url <- ["http://app.example.test/webhooks/telegram", "app.example.test", ""] do
        assert WebhookRegistration.register(@bot_token, @secret_token, url) ==
                 {:error, :invalid_webhook_url}
      end

      Req.Test.verify!(__MODULE__)
    end
  end

  describe "secrets hygiene" do
    test "no error, description or log line carries the token or the secret" do
      leaky = "Bad Request for /bot#{@bot_token}/setWebhook with #{@secret_token}\nsecond line"

      scenarios = [
        fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"ok" => false, "error_code" => 400, "description" => leaky})
        end,
        fn conn -> Req.Test.json(conn, %{"ok" => false, "description" => leaky}) end,
        fn conn -> conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"ok" => false}) end,
        fn conn -> Plug.Conn.send_resp(conn, 502, leaky) end,
        &Req.Test.transport_error(&1, :econnrefused),
        fn _conn -> raise "unexpected failure for #{@bot_token}" end
      ]

      {results, log} =
        ExUnit.CaptureLog.with_log(fn ->
          for scenario <- scenarios do
            expect_webhook_info(%{"url" => "", "pending_update_count" => 0})
            Req.Test.expect(__MODULE__, scenario)

            WebhookRegistration.register(@bot_token, @secret_token, @webhook_url)
          end
        end)

      assert Enum.all?(results, &match?({:error, _reason}, &1))

      assert [
               {:error, {:telegram, 400, description}},
               {:error, {:telegram, 200, _}},
               {:error, {:rate_limited, nil}},
               {:error, {:telegram, 502, nil}},
               {:error, {:transport, :connection}},
               {:error, :unexpected}
             ] = results

      refute description =~ "\n"

      texts =
        [inspect(results, limit: :infinity, printable_limit: :infinity), log] ++
          Enum.map(results, fn {:error, reason} -> WebhookRegistration.message(reason) end)

      for text <- texts do
        refute text =~ @bot_token
        refute text =~ @secret_token
      end
    end

    test "a successful registration logs nothing secret" do
      log =
        capture_log(fn ->
          expect_webhook_info(%{"url" => "", "pending_update_count" => 0})
          Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"ok" => true, "result" => true}))
          expect_webhook_info(registered_info())

          assert {:ok, result} =
                   WebhookRegistration.register(@bot_token, @secret_token, @webhook_url)

          refute inspect(result) =~ @bot_token
          refute inspect(result) =~ @secret_token
        end)

      refute log =~ @bot_token
      refute log =~ @secret_token
    end
  end

  describe "webhook_url/1" do
    test "builds the HTTPS URL of the webhook route from a bare host" do
      assert WebhookRegistration.webhook_url("app.example.test") == @webhook_url
    end

    test "the path is the POST route the Telegram webhook controller serves" do
      assert %{plug: AletheaWeb.TelegramWebhookController, plug_opts: :update} =
               Phoenix.Router.route_info(
                 AletheaWeb.Router,
                 "POST",
                 WebhookRegistration.webhook_path(),
                 "app.example.test"
               )
    end
  end

  describe "allowed_updates/0" do
    test "is limited to the update type the webhook controller handles" do
      assert WebhookRegistration.allowed_updates() == ["message"]
    end
  end

  defp registered_info(overrides \\ %{}) do
    Map.merge(
      %{"url" => @webhook_url, "pending_update_count" => 0, "allowed_updates" => ["message"]},
      overrides
    )
  end

  defp expect_webhook_info(result) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/bot#{@bot_token}/getWebhookInfo"

      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)
  end

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
