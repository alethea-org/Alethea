defmodule Alethea.Telegram.BotTokenTest do
  @moduledoc """
  Tests for `Alethea.Telegram.BotToken` GenServer accessor (C-6).

  Covers:
  - `REQ-C6-bot-token-gen-server-accessor`: the GenServer loads the
    `BotConfig.for_env(Mix.env())` row at boot, holds the plaintext
    tokens in process state, and serves them via synchronous
    `GenServer.call/2`.
  - `REQ-C6-no-plaintext-in-env`: a missing row causes a fail-loud
    error at boot, not a silent default.
  - The reload hook picks up a new row without an app restart.
  """

  use Alethea.DataCase, async: false

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Telegram.BotToken

  setup do
    # The GenServer is a separate OTP process; the SQL sandbox must
    # explicitly allow it. The owner process (this test pid) is the
    # default; we extend that allow list to the GenServer's pid when
    # we start it.
    BotToken.stop()
    Repo.delete_all(BotConfig)
    :ok
  end

  defp start_bot_token! do
    # Allow the GenServer process to share the test's sandbox connection.
    # Without this, the GenServer's `init/1` will hit the sandbox
    # ownership check and crash with `db_connection_owner_not_found`.
    {:ok, pid} = BotToken.start_link([])

    Ecto.Adapters.SQL.Sandbox.allow(Alethea.Repo, self(), pid)
    :ok
  end

  describe "start_link/1 — boots from the seeded BotConfig row" do
    test "loads the bot_token, secret_token, and bot_username from the env row" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "test-bot-token-123",
          secret_token: "test-secret-token",
          bot_username: "alethea_test_bot"
        })

      :ok = start_bot_token!()

      assert BotToken.bot_token() == "test-bot-token-123"
      assert BotToken.secret_token() == "test-secret-token"
      assert BotToken.bot_username() == "alethea_test_bot"
    end
  end

  describe "init/1 — fail-loud on missing row (REQ-C6-no-plaintext-in-env)" do
    test "the GenServer refuses to start when no BotConfig row exists for the env" do
      # No row is seeded; the GenServer must refuse to start. `start_link/1`
      # traps the EXIT signal because `init/1` raised; the linked caller
      # receives an `{:error, {reason, stack}}` tuple.
      Process.flag(:trap_exit, true)

      assert {:error, {%RuntimeError{message: msg}, _stack}} = BotToken.start_link([])

      assert msg =~ "no BotConfig row for env=test"
    end
  end

  describe "reload — re-reads the row from the DB" do
    test "BotToken.reload/0 (cast path, public API) re-reads the row from the DB" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "old-token",
          secret_token: "old-secret",
          bot_username: "old_username"
        })

      :ok = start_bot_token!()
      pid = Process.whereis(BotToken)

      # Sanity check the initial load.
      assert BotToken.bot_token() == "old-token"

      # Update the row, then ask the GenServer to reload via the
      # public `BotToken.reload/0` API (which is `GenServer.cast/2`,
      # i.e. `handle_cast/2`).
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "new-token",
          secret_token: "new-secret",
          bot_username: "new_username"
        })

      BotToken.reload()
      # Drain the inbox so the GenServer processes the :reload before the
      # next call. `_ = :sys.get_state/1` is the project-discipline sync
      # primitive: it forces a synchronous exchange that proves the
      # GenServer has handled the prior `:reload` message.
      _ = :sys.get_state(pid)

      assert BotToken.bot_token() == "new-token"
      assert BotToken.secret_token() == "new-secret"
      assert BotToken.bot_username() == "new_username"
    end

    test "send(pid, :reload) (info path) re-reads the row from the DB" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "old-token-info",
          secret_token: "old-secret-info",
          bot_username: "old_username_info"
        })

      :ok = start_bot_token!()
      pid = Process.whereis(BotToken)

      assert BotToken.bot_token() == "old-token-info"

      # Update the row.
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "new-token-info",
          secret_token: "new-secret-info",
          bot_username: "new_username_info"
        })

      send(pid, :reload)
      _ = :sys.get_state(pid)

      assert BotToken.bot_token() == "new-token-info"
      assert BotToken.secret_token() == "new-secret-info"
      assert BotToken.bot_username() == "new_username_info"
    end
  end

  describe "GenServer state — plaintext is held in process state" do
    test "bot_token/0 is served from process state, not from a DB read on every call" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "stable-token",
          secret_token: "stable-secret",
          bot_username: "stable_username"
        })

      :ok = start_bot_token!()

      # Update the row directly via the schema — bypassing the GenServer.
      # The next GenServer call MUST return the OLD value (process state
      # is the source of truth until :reload is sent).
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "unstable-token",
          secret_token: "unstable-secret",
          bot_username: "unstable_username"
        })

      assert BotToken.bot_token() == "stable-token"
    end
  end

  describe "reload — failure path is loud (W-1)" do
    import ExUnit.CaptureLog

    test "send(pid, :reload) — when the row is gone, logs a Logger.error and resets to nil" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "live-token",
          secret_token: "live-secret",
          bot_username: "live_username"
        })

      :ok = start_bot_token!()
      pid = Process.whereis(BotToken)

      # Sanity: the GenServer is up and serving the seeded values.
      assert BotToken.bot_token() == "live-token"

      # Wipe the row to simulate a delete-while-running.
      Repo.delete_all(BotConfig)

      # The :reload message via send/2 (handle_info) MUST log a
      # Logger.error and reset state to nil. The fail-closed behaviour
      # is preserved (webhooks 401 on nil token), but the operator now
      # sees an alert.
      log =
        capture_log(fn ->
          send(pid, :reload)
          _ = :sys.get_state(pid)
        end)

      # State is reset to nil — fail-closed.
      assert BotToken.bot_token() == nil
      assert BotToken.secret_token() == nil
      assert BotToken.bot_username() == nil

      # The GenServer is still alive (we did not raise).
      assert Process.alive?(pid)

      # The log message is clear and contains the env and the
      # :not_found whitelist tag.
      assert log =~ "Alethea.Telegram.BotToken"
      assert log =~ "env=test"
      assert log =~ ":not_found"
      assert log =~ "reload"

      # The previous plaintext token MUST NOT be in the log.
      refute log =~ "live-token"
      refute log =~ "live-secret"
    end

    test "BotToken.reload/0 (cast) — when the row is gone, logs a Logger.error and resets to nil" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "live-token-2",
          secret_token: "live-secret-2",
          bot_username: "live_username_2"
        })

      :ok = start_bot_token!()
      pid = Process.whereis(BotToken)

      assert BotToken.bot_token() == "live-token-2"

      # Wipe the row.
      Repo.delete_all(BotConfig)

      # The public API uses GenServer.cast/2 (handle_cast/2). Same
      # fail-loud-and-reset behaviour as the info path.
      log =
        capture_log(fn ->
          BotToken.reload()
          _ = :sys.get_state(pid)
        end)

      # State is reset to nil.
      assert BotToken.bot_token() == nil
      assert BotToken.secret_token() == nil
      assert BotToken.bot_username() == nil

      # The GenServer is still alive.
      assert Process.alive?(pid)

      # The log message is clear.
      assert log =~ "Alethea.Telegram.BotToken"
      assert log =~ "env=test"
      assert log =~ ":not_found"

      # The previous plaintext token MUST NOT be in the log.
      refute log =~ "live-token-2"
      refute log =~ "live-secret-2"
    end
  end

  describe "stop/0 — test helper" do
    test "stops the GenServer if running" do
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "t",
          secret_token: "s",
          bot_username: "u"
        })

      :ok = start_bot_token!()
      assert :ok = BotToken.stop()
    end

    test "stop is a no-op if the GenServer is not running" do
      # Should not raise; returns :ok whether or not the process exists.
      assert :ok = BotToken.stop()
    end
  end

  describe "format_status/1 — redaction of plaintext in introspection output (F-04)" do
    test ":sys.get_status/1 redacts :bot_token and :secret_token (plaintext is not in the human-readable status)" do
      # The moduledoc claims the plaintext is not in the human-readable
      # status. `:sys.get_status/1` is the introspection path that
      # actually invokes `format_status/2`; the redaction lives there.
      # (`:sys.get_state/1` does NOT route through `format_status/2` in
      # OTP — it returns the raw state struct, which is why the
      # moduledoc warns "the process pid is secret-bearing" and
      # "raw state access still requires an explicit, privileged call".)
      #
      # The contract: the bot_token and secret_token MUST appear as
      # `"[REDACTED]"` in the human-readable status; the bot_username
      # (a non-secret public handle) is allowed through.
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "visible-in-introspection",
          secret_token: "also-visible-in-introspection",
          bot_username: "public_username"
        })

      :ok = start_bot_token!()
      pid = Process.whereis(BotToken)

      # `:sys.get_status/1` invokes `format_status/2` internally.
      # The redacted status must NOT contain the plaintext.
      status = :sys.get_status(pid)
      flat = inspect(status)

      refute flat =~ "visible-in-introspection"
      refute flat =~ "also-visible-in-introspection"
      # The redacted form is present (defence in depth — also confirms
      # we are actually invoking the format_status path, not bypassing it).
      assert flat =~ "[REDACTED]"
      # The non-secret handle is allowed through.
      assert flat =~ "public_username"
    end
  end

  describe "init/1 — whitelist reason tag (W-2)" do
    test "reason_tag/1 is a whitelist match — never inspect/1 — so a non-trivial :unexpected payload never reaches the log" do
      # The :not_found reason: the most common case (row deleted). The
      # tag is the literal atom string, which is safe to log.
      assert BotToken.reason_tag(:not_found) == ":not_found"

      # The :unexpected reason: a non-trivial payload (e.g. a
      # %BotConfig{} struct with ciphertext blobs, ids, etc.). The
      # WHITELIST match discards the payload and returns just the
      # tag. This is the W-2 fix: a defence-in-depth guarantee that
      # init/1's Logger.error never leaks the struct's fields.
      assert BotToken.reason_tag({:unexpected, %BotConfig{}}) == ":unexpected"

      # A non-trivial :unexpected payload with sensitive-looking data
      # — the tag still does NOT include the payload.
      sensitive = %BotConfig{
        id: "secret-uuid",
        env: "test",
        bot_token: "sensitive-token",
        secret_token: "sensitive-secret",
        bot_username: "sensitive_username"
      }

      tag = BotToken.reason_tag({:unexpected, sensitive})
      assert tag == ":unexpected"
      # Defence in depth: the tag string is exactly the whitelist
      # value, with no payload data appended.
      assert tag == ":unexpected"
      refute tag =~ "secret-uuid"
      refute tag =~ "sensitive-token"
      refute tag =~ "sensitive-secret"

      # Any other term: mapped to "other" (the catch-all bucket).
      assert BotToken.reason_tag(:something_else) == "other"
      assert BotToken.reason_tag({:weird, "shape"}) == "other"
      assert BotToken.reason_tag(%{anything: 42}) == "other"
    end

    test "init/1 logs the whitelist tag for the :not_found reason (regression for the W-2 substitution)" do
      # The init/1 path that fires when no BotConfig row exists for
      # the env. The log message MUST contain the :not_found tag (it
      # did with `inspect(reason)` too, but this test pins the new
      # code path) and MUST NOT contain `inspect` output of any other
      # reason.
      import ExUnit.CaptureLog

      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert {:error, {%RuntimeError{message: msg}, _stack}} = BotToken.start_link([])

          assert msg =~ "no BotConfig row for env=test"
        end)

      # The whitelist tag is in the log.
      assert log =~ "Alethea.Telegram.BotToken failed to boot"
      assert log =~ "env=test"
      assert log =~ "(reason: :not_found)"
    end
  end
end
