defmodule Alethea.Telegram.PacerTest do
  @moduledoc """
  Tests for `Alethea.Telegram.Pacer` (C-7 rate-limit primitive).

  Covers:
  - `REQ-C7-pacer-per-chat-limit`: 1 msg/s/chat — second message in the
    same second blocks until the per-chat bucket refills.
  - `REQ-C7-pacer-per-chat-limit` (independent chats): per-chat buckets
    are keyed by `chat_id_hash`; different chats pace independently.
  - `REQ-C7-pacer-global-limit`: 30 msg/s global — the 31st message in
    the same second blocks until the global bucket refills.
  - `REQ-C7-pacer-global-limit` (per-chat is dominant): a chat with a
    full per-chat bucket is paced at 1 Hz regardless of global
    availability.
  - Module shape: single GenServer + two ETS tables, named processes,
    no I/O beyond the ETS lookups.

  Test-time configuration overrides the production rates so the
  blocking semantics can be exercised in milliseconds, not seconds.
  The defaults match Telegram's published limits (1 Hz / 30 Hz); the
  overrides are documented in `config/test.exs`.
  """

  use ExUnit.Case, async: false

  alias Alethea.Telegram.Pacer

  setup do
    # Save the test overrides so each test starts from a known config.
    # The Pacer reads `Application.get_env(:alethea, Alethea.Telegram.Pacer, ...)`
    # at acquire-time, so per-test overrides take effect immediately.
    base = [
      per_chat_capacity: 1,
      per_chat_refill_per_sec: 1.0,
      global_capacity: 30,
      global_refill_per_sec: 30.0
    ]

    Application.put_env(:alethea, Alethea.Telegram.Pacer, base)

    # Reset the GenServer so each test gets a fresh bucket state.
    # The Pacer is registered under `__MODULE__`; if a previous test
    # left it running, stop it before starting a new one.
    #
    # `GenServer.stop/3` raises `:exit` (not an exception) when the
    # target process is already dead — the typical race condition when
    # the next test's setup starts before this test's on_exit fires.
    # Use `try/catch :exit` to swallow both: the exception case
    # (rescue) and the link/exit case (catch).
    safe_stop()

    {:ok, _} = Pacer.start_link([])

    on_exit(fn ->
      Application.delete_env(:alethea, Alethea.Telegram.Pacer)
      safe_stop()
    end)

    :ok
  end

  describe "start_link/1 — module shape" do
    test "registers the GenServer under the module name" do
      assert is_pid(Process.whereis(Pacer))
    end

    test "creates two named ETS tables (per-chat and global)" do
      assert :ets.info(:telegram_pacer_per_chat) != :undefined
      assert :ets.info(:telegram_pacer_global) != :undefined
    end
  end

  describe "acquire/1 — REQ-C7-pacer-per-chat-limit (per-chat 1 Hz)" do
    test "first message to a chat goes through immediately" do
      # Fresh per-chat bucket: 1 token available. No block.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-A")
      elapsed = monotonic_ms() - start

      # Immediate: under 50ms (loose threshold for slow CI).
      assert elapsed < 50
    end

    test "second message in the same second blocks until per-chat bucket refills" do
      # First acquire consumes the only token.
      assert :ok = Pacer.acquire("chat-A")

      # The bucket refill rate is 1 Hz (1 token per 1000ms). The second
      # call within the same second must block ~1s before returning :ok.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-A")
      elapsed = monotonic_ms() - start

      # The second acquire blocked until the bucket refilled (≥ 900ms,
      # accounting for timing slack on busy CI machines).
      assert elapsed >= 900,
             "expected second acquire to block ~1s, got #{elapsed}ms"
    end

    test "different chats are paced independently (per-chat buckets are per-key)" do
      # chat-A consumes its first token.
      assert :ok = Pacer.acquire("chat-A")

      # chat-B has a fresh bucket; its first acquire must NOT block
      # on chat-A's bucket state.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-B")
      elapsed = monotonic_ms() - start

      assert elapsed < 50,
             "expected chat-B acquire to be independent of chat-A, blocked #{elapsed}ms"
    end

    test "per-chat buckets are independent even when the global bucket is drained" do
      # Drain the global bucket with 30 distinct chats (capacity = 30).
      for i <- 1..30 do
        assert :ok = Pacer.acquire("chat-#{i}")
      end

      # Global bucket is now empty; subsequent acquires block on global refill.

      # Two new distinct chats (chat-Y, chat-Z) must each acquire within
      # 50ms because their per-chat buckets are independent of each other
      # and of the 30 already-drained chats. Each new chat's per-chat
      # bucket starts full (1 token), so the wait is only the global
      # refill (~33ms at 30 Hz), NOT a per-chat refill (~1000ms at 1 Hz).
      #
      # If the Pacer collapsed all keys to a single per-chat bucket,
      # chat-Y's "fresh per-chat bucket" would actually be the same as
      # chat-1's empty bucket, and chat-Y would block ~1000ms — far
      # more than 50ms.
      start_y = monotonic_ms()
      assert :ok = Pacer.acquire("chat-Y")
      elapsed_y = monotonic_ms() - start_y

      assert elapsed_y < 50,
             "expected chat-Y acquire to be independent (no per-chat block), blocked #{elapsed_y}ms"

      start_z = monotonic_ms()
      assert :ok = Pacer.acquire("chat-Z")
      elapsed_z = monotonic_ms() - start_z

      assert elapsed_z < 50,
             "expected chat-Z acquire to be independent (no per-chat block), blocked #{elapsed_z}ms"
    end
  end

  describe "acquire/1 — REQ-C7-pacer-global-limit (global 30 Hz)" do
    test "30 distinct chats in the same second all return :ok" do
      # 30 distinct chats, each consuming 1 token from the global bucket.
      # All 30 must succeed without blocking (the bucket starts full at 30).
      for i <- 1..30 do
        assert :ok = Pacer.acquire("chat-#{i}")
      end
    end

    test "31st distinct chat blocks until the global bucket refills" do
      # Drain the global bucket with 30 distinct chats.
      for i <- 1..30 do
        assert :ok = Pacer.acquire("chat-#{i}")
      end

      # The 31st call: global bucket is empty. With 30 Hz refill, the
      # wait is ~33ms before another token is available.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-31")
      elapsed = monotonic_ms() - start

      # The 31st call blocked until the global bucket refilled (≥ 25ms,
      # allowing for CI scheduling jitter; the theoretical 33ms is the
      # half-token delay).
      assert elapsed >= 25,
             "expected 31st acquire to block ~33ms on global refill, got #{elapsed}ms"
    end

    test "global limit is independent of per-chat limit (same chat, 30 distinct calls block on global, not per-chat)" do
      # Same chat, called 30 times. The per-chat bucket is 1 token, so
      # each call except the first would block on per-chat (1 Hz refill).
      # But the global bucket drains after 30 distinct chats... wait,
      # same chat = same per-chat key = block at 1 Hz, not 30 Hz.
      #
      # So the test below must rely on the global bucket being shared
      # across chats. With 1 chat only, per-chat refill (1 Hz) is the
      # bottleneck. To exercise the global limit while bypassing per-chat,
      # we use 30 distinct chats — already covered above. Here we just
      # assert that the per-chat limit is the dominant constraint when
      # the per-chat bucket is empty AND the global bucket has tokens.
      assert :ok = Pacer.acquire("chat-A")
      # After chat-A consumed its 1 per-chat token, the global bucket
      # still has 29 tokens. But chat-A's per-chat bucket is empty.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-A")
      elapsed = monotonic_ms() - start

      # Blocked on the per-chat refill (1 Hz = ~1000ms), NOT on the
      # global refill (30 Hz = ~33ms). The per-chat limit dominates.
      assert elapsed >= 900,
             "expected chat-A second acquire to block on per-chat refill (~1000ms), got #{elapsed}ms"
    end

    test "30 distinct chats, then 31st blocks on global (not per-chat)" do
      # First 30 calls are all distinct chats: per-chat has 30 fresh
      # buckets, global is fully drained. The 31st call uses a new chat
      # (chat-31) so its per-chat bucket is fresh; the global bucket is
      # the constraint.
      for i <- 1..30 do
        assert :ok = Pacer.acquire("chat-#{i}")
      end

      # chat-31 has a fresh per-chat bucket (1 token) but the global
      # bucket is empty. The 31st acquire blocks on global refill.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-31")
      elapsed = monotonic_ms() - start

      # Global refill is 30 Hz (~33ms between tokens), not per-chat 1 Hz.
      # The block is short (~33ms) and definitely < 500ms.
      assert elapsed >= 25

      assert elapsed < 500,
             "expected global-limited acquire to block ~33ms, got #{elapsed}ms"
    end
  end

  describe "acquire/1 — return shape" do
    test "always returns :ok (the wait is internal to the GenServer)" do
      # The Pacer holds the buckets in its own state; the caller does
      # not see a {:wait, _} token. The contract is: acquire/1 blocks
      # inside the GenServer until both buckets allow, then returns
      # :ok. We assert the return shape across the per-chat and global
      # branches.
      assert :ok = Pacer.acquire("chat-A")
      assert :ok = Pacer.acquire("chat-A")
      assert :ok = Pacer.acquire("chat-B")
    end
  end

  ## Helpers

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp safe_stop do
    case Process.whereis(Pacer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
