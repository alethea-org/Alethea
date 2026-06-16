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

  describe "handle_info(:reload, _) — re-reads the row from the DB" do
    test "the next call returns the updated plaintext values" do
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

      # Update the row, then ask the GenServer to reload.
      {:ok, _} =
        BotConfig.upsert(%{
          env: "test",
          bot_token: "new-token",
          secret_token: "new-secret",
          bot_username: "new_username"
        })

      send(pid, :reload)
      # Drain the inbox so the GenServer processes the :reload before the
      # next call. `_ = :sys.get_state/1` is the project-discipline sync
      # primitive: it forces a synchronous exchange that proves the
      # GenServer has handled the prior `:reload` message.
      _ = :sys.get_state(pid)

      assert BotToken.bot_token() == "new-token"
      assert BotToken.secret_token() == "new-secret"
      assert BotToken.bot_username() == "new_username"
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
end
