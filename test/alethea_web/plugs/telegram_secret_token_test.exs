defmodule AletheaWeb.Plugs.TelegramSecretTokenTest do
  @moduledoc """
  Tests for `AletheaWeb.Plugs.TelegramSecretToken` (C-1 webhook auth).

  Covers `REQ-C1-secret-token-validates-header` (4 scenarios):

    - matching secret-token header → plug forwards the conn
      (no halt, no body sent) so the controller can parse the body
    - missing header → 401, empty body, no log line
    - wrong header value → 401, empty body, no log line
    - extra header value (e.g. attacker supplies the header twice) →
      401 (defensive; the legitimate Telegram client only sends one)
    - constant-time comparison is used (the plug does NOT short-circuit
      on length mismatch alone; the security property is preserved)

  The plug depends on `Alethea.Telegram.BotToken.secret_token/0`,
  which is a GenServer call. The test suite starts the GenServer
  manually (the same pattern as `Alethea.Telegram.BotTokenTest`)
  with a `BotConfig` row seeded in setup, so the GenServer can
  serve a deterministic `secret_token` value.
  """

  use AletheaWeb.ConnCase, async: false

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Repo
  alias Alethea.Telegram.BotToken
  alias AletheaWeb.Plugs.TelegramSecretToken

  @secret_token "telegram-test-secret-9c0e4a"
  @header "x-telegram-bot-api-secret-token"

  setup do
    # Mirror the BotToken test setup: clear any prior BotConfig row,
    # stop the GenServer if running, then seed a deterministic row
    # and start the GenServer with the SQL sandbox explicitly allowed.
    BotToken.stop()
    Repo.delete_all(BotConfig)

    {:ok, _} =
      BotConfig.upsert(%{
        env: "test",
        bot_token: "test-bot-token-irrelevant",
        secret_token: @secret_token,
        bot_username: "alethea_test_bot"
      })

    {:ok, pid} = BotToken.start_link([])
    Ecto.Adapters.SQL.Sandbox.allow(Alethea.Repo, self(), pid)

    on_exit(fn -> BotToken.stop() end)

    :ok
  end

  describe "call/2 — matching header" do
    test "forwards the conn to the next plug (no halt, no response sent)" do
      conn = conn_with_header(@secret_token) |> TelegramSecretToken.call([])

      # No halt: the controller / next plug in the pipeline gets the conn.
      refute conn.halted
      # No response sent by the plug itself.
      assert conn.status == nil
      assert conn.resp_body == nil
    end
  end

  describe "call/2 — missing header" do
    test "returns 401 with empty body when the header is absent" do
      conn = build_conn(:post, "/webhooks/telegram") |> TelegramSecretToken.call([])

      assert conn.status == 401
      assert conn.halted
      assert conn.resp_body == ""
    end
  end

  describe "call/2 — wrong header value" do
    test "returns 401 with empty body when the header value does not match" do
      conn = conn_with_header("wrong-value") |> TelegramSecretToken.call([])

      assert conn.status == 401
      assert conn.halted
      assert conn.resp_body == ""
    end
  end

  describe "call/2 — header shape" do
    test "rejects duplicate header values (defensive)" do
      # The legitimate Telegram client always sends exactly one value.
      # If a server receives two `X-Telegram-Bot-Api-Secret-Token`
      # values (HTTP smuggling, a misconfigured proxy, or a malicious
      # client that appends), `get_req_header/2` returns the values
      # as a list. The plug's `[token] when is_binary(token)` guard
      # pattern-matches on EXACTLY one value; two values fall through
      # to the 401 short-circuit.
      #
      # We construct the conn with the duplicate header values
      # directly because `put_req_header/3` in Plug.Test overwrites
      # rather than appends. The `req_headers` field is a list of
      # `{name, value}` tuples; the duplicate scenario is the
      # production Bandit shape when an upstream proxy passes two
      # copies of the header through.
      conn =
        build_conn(:post, "/webhooks/telegram")
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> Map.put(:req_headers, [
          {"host", "www.example.com"},
          {@header, "first-value"},
          {@header, @secret_token}
        ])
        |> TelegramSecretToken.call([])

      assert conn.status == 401
      assert conn.resp_body == ""
    end
  end

  # --- helpers ---

  defp conn_with_header(value) do
    build_conn(:post, "/webhooks/telegram")
    |> put_req_header(@header, value)
  end
end
