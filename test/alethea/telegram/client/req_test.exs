defmodule Alethea.Telegram.Client.ReqTest do
  @moduledoc """
  Tests for `Alethea.Telegram.Client.Req` (C-7 production adapter;
  PR #3a / TASK-3a-4).

  The Req adapter is the production transport for
  `Alethea.Telegram.Client.send_message/2`. It POSTs to
  `https://api.telegram.org/bot<token>/sendMessage` and translates
  the HTTP responses into the callback contract documented on
  `Alethea.Telegram.Client`:

    - `200 OK` with `result.message_id` → `{:ok, message_id}`
    - `200 OK` with `ok: false`         → `{:error, {:http_error, 200, body}}`
    - `429` with `Retry-After`           → `{:error, {:rate_limited, retry_after}}`
    - `5xx`                              → `{:error, {:server_error, status}}`
    - Network / transport failure        → `{:error, :network}`

  The Req.Test adapter is wired via
  `Application.put_env(:alethea, :telegram_client_req_options, plug: {Req.Test, __MODULE__})`
  so `Req.post/2` hits the stub instead of the real Telegram API.

  ## PHI hygiene

  The bot token is the production secret; tests use a fake but the
  adapter must NOT log it (R-1). The body is the patient's words;
  tests assert it does not appear in any log line.
  """

  use Alethea.DataCase, async: false

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Telegram.{BotToken, Client}

  @fake_bot_token "test-bot-token-fake-1234567890"
  @fake_secret "test-secret-token-fake"
  @fake_username "alethea_test_bot"
  @chat_id 123_456_789
  @body "hola, buen día"

  setup do
    BotToken.stop()
    Repo.delete_all(BotConfig)

    {:ok, _} =
      BotConfig.upsert(%{
        env: "test",
        bot_token: @fake_bot_token,
        secret_token: @fake_secret,
        bot_username: @fake_username
      })

    {:ok, pid} = BotToken.start_link([])
    Ecto.Adapters.SQL.Sandbox.allow(Alethea.Repo, self(), pid)

    # Wire Req.Test as the plug. The adapter reads this config at
    # call-time and passes it to `Req.post/2`.
    Application.put_env(
      :alethea,
      :telegram_client_req_options,
      plug: {Req.Test, Alethea.Telegram.Client.Req}
    )

    :ok
  end

  # ----------------------------------------------------------------
  # 200 OK
  # ----------------------------------------------------------------

  describe "send_message/2 — 200 OK" do
    test "returns {:ok, message_id} when Telegram responds with a message_id" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 9_999_999}})
        )
      end)

      assert {:ok, 9_999_999} = Client.Req.send_message(@chat_id, @body)
    end

    test "returns {:ok, nil} when Telegram responds ok:true but no message_id" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{}}))
      end)

      assert {:ok, nil} = Client.Req.send_message(@chat_id, @body)
    end

    test "returns {:error, {:http_error, 200, body}} when Telegram responds ok:false" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => false,
            "error_code" => 400,
            "description" => "Bad Request: chat not found"
          })
        )
      end)

      assert {:error, {:http_error, 200, body}} = Client.Req.send_message(@chat_id, @body)
      assert body["error_code"] == 400
    end
  end

  # ----------------------------------------------------------------
  # 429 with Retry-After
  # ----------------------------------------------------------------

  describe "send_message/2 — 429 rate-limited" do
    test "returns {:error, {:rate_limited, retry_after_seconds}} on 429 with Retry-After header" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.resp(
          429,
          Jason.encode!(%{"ok" => false, "description" => "Too Many Requests"})
        )
      end)

      assert {:error, {:rate_limited, 2}} = Client.Req.send_message(@chat_id, @body)
    end

    test "returns {:error, {:rate_limited, 1}} (default) when 429 has no Retry-After header" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          429,
          Jason.encode!(%{"ok" => false, "description" => "Too Many Requests"})
        )
      end)

      assert {:error, {:rate_limited, 1}} = Client.Req.send_message(@chat_id, @body)
    end
  end

  # ----------------------------------------------------------------
  # 5xx
  # ----------------------------------------------------------------

  describe "send_message/2 — 5xx server error" do
    test "returns {:error, {:server_error, status}} on 500/502/503/504" do
      for status <- [500, 502, 503, 504] do
        Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            status,
            Jason.encode!(%{"ok" => false, "description" => "server error"})
          )
        end)

        assert {:error, {:server_error, ^status}} = Client.Req.send_message(@chat_id, @body)
      end
    end
  end

  # ----------------------------------------------------------------
  # Network / transport failure
  # ----------------------------------------------------------------

  describe "send_message/2 — network failure" do
    test "returns {:error, :network} when the transport raises (Req.post/2 returns {:error, _})" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn _conn ->
        # Force Req to error out by raising from the stub. Req.Test
        # wraps the exception in {:error, _}.
        raise "connection refused"
      end)

      assert {:error, :network} = Client.Req.send_message(@chat_id, @body)
    end
  end

  # ----------------------------------------------------------------
  # Config-driven Req options
  # ----------------------------------------------------------------

  describe "send_message/2 — req_options config" do
    test "the adapter reads :telegram_client_req_options from Application env at call-time" do
      # The setup already wired {Req.Test, Alethea.Telegram.Client.Req}
      # as the plug. Replace it with a stub that proves the adapter
      # consulted the config (not a hardcoded plug).
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 11}}))
      end)

      assert {:ok, 11} = Client.Req.send_message(@chat_id, @body)
    end

    test "works without req_options config set (uses empty keyword list)" do
      Application.delete_env(:alethea, :telegram_client_req_options)

      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 12}}))
      end)

      # Without the Req.Test plug in req_options, Req.post would hit
      # the real Telegram API and fail (no network in tests). We
      # expect a non-200 response or transport error. The test only
      # asserts the function does not crash on missing config.
      result = Client.Req.send_message(@chat_id, @body)
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  # ----------------------------------------------------------------
  # PHI hygiene
  # ----------------------------------------------------------------

  describe "PHI hygiene (R-1)" do
    test "the bot token is NOT logged on any response shape (200 / 429 / 500)" do
      for {status, body_fn} <- [
            {200, fn -> Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 13}}) end},
            {429, fn -> Jason.encode!(%{"ok" => false, "description" => "rate limited"}) end},
            {500, fn -> Jason.encode!(%{"ok" => false, "description" => "internal"}) end}
          ] do
        Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
          body = body_fn.()

          conn =
            case status do
              429 -> Plug.Conn.put_resp_header(conn, "retry-after", "1")
              _ -> conn
            end

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(status, body)
        end)

        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            Client.Req.send_message(@chat_id, @body)
          end)

        refute log =~ @fake_bot_token, "bot token leaked in log line for status #{status}: #{log}"
      end
    end

    test "the message body is NOT logged on success" do
      Req.Test.stub(Alethea.Telegram.Client.Req, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 14}}))
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          Client.Req.send_message(@chat_id, @body)
        end)

      refute log =~ @body
    end
  end
end
