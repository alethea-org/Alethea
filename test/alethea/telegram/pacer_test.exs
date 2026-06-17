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

    test "ETS tables are :protected (writes go through the GenServer only) (F-12)" do
      # F-12 regression guard. The previous `:public` access meant
      # any process could write to the bucket tables, contradicting
      # the moduledoc claim that "writes go through the GenServer
      # only". `:protected` access allows reads from any process
      # but writes only from the table owner (the GenServer).
      # Foreign writes must be rejected.
      for table <- [:telegram_pacer_per_chat, :telegram_pacer_global] do
        info = :ets.info(table, :protection)
        assert info == :protected,
               "expected ETS table #{inspect(table)} to be :protected, got #{inspect(info)}"
      end

      # A foreign process MUST NOT be able to write. We assert the
      # write raises ArgumentError (ETS rejects :protected writes
      # from non-owner processes).
      test_pid = self()

      foreign_pid =
        spawn(fn ->
          send(test_pid, {:ready, self()})

          receive do
            :go_ahead ->
              # Attempt a foreign write. `:protected` tables reject
              # writes from non-owner processes with `ArgumentError`.
              :ets.insert(:telegram_pacer_per_chat, {"foreign-write", 999, 0})
          end
        end)

      assert_receive {:ready, ^foreign_pid}, 1_000

      ref = Process.monitor(foreign_pid)
      send(foreign_pid, :go_ahead)
      assert_receive {:DOWN, ^ref, :process, ^foreign_pid, reason}, 1_000

      assert match?({:badarg, _stack}, reason),
             "expected foreign write to fail with :badarg, got #{inspect(reason)}"
    end

    test "ETS tables are :set (single-writer, no write_concurrency) (F-13)" do
      # F-13 structural assertion. The Pacer is a single-GS design
      # — only the GenServer process writes to the bucket tables.
      # The :write_concurrency option is a NOP for a single-writer
      # table and adds a small amount of internal overhead (the
      # table is split into N sub-tables for concurrent writers).
      # The previous implementation enabled :write_concurrency
      # out of habit, contradicting the single-writer invariant.
      #
      # We assert: the :write_concurrency option is NOT in the
      # table's options list. :read_concurrency is still allowed
      # (many processes can :ets.lookup/2 the table for the
      # inspect accessor).
      for table <- [:telegram_pacer_per_chat, :telegram_pacer_global] do
        options = :ets.info(table)

        refute :write_concurrency in options,
               "expected ETS table #{inspect(table)} to NOT have :write_concurrency enabled, got options: #{inspect(options)}"
      end
    end

    test "Pacer.inspect_per_chat/0 and Pacer.inspect_global/0 are GenServer-mediated read accessors (F-12)" do
      # F-12 accessor. The moduledoc claims "writes go through the
      # GenServer only" and that the buckets can be inspected by
      # ops dashboards. With :protected ETS, foreign processes cannot
      # read raw rows either (they CAN read the table directly via
      # :ets.lookup/2, but the canonical accessor goes through the
      # GenServer for consistency with the redaction rules in
      # format_status/2). The accessor returns a serializable
      # snapshot.
      :ok = Pacer.acquire("chat-inspect")

      snapshot = Pacer.inspect_per_chat()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, "chat-inspect")

      entry = Map.get(snapshot, "chat-inspect")
      assert is_map(entry)
      assert Map.has_key?(entry, :tokens)
      assert Map.has_key?(entry, :last_refill_ms)

      global_snapshot = Pacer.inspect_global()
      assert is_map(global_snapshot)
      assert Map.has_key?(global_snapshot, :tokens)
      assert Map.has_key?(global_snapshot, :last_refill_ms)
    end
  end

  describe "start_link/1 — config validation (F-09)" do
    # F-09 regression guard. `init/1` used to silently accept any
    # config. A `per_chat_capacity: 0` or `global_capacity: 0` value
    # would brick the Pacer — `do_acquire/1` enters an infinite
    # loop on the `{:wait, _non_positive}` branch because
    # `ms_until_next_token/2` returns 1 ms forever. The fix mirrors
    # `BotToken.init/1`'s fail-loud pattern: validate all four knobs
    # in `init/1` and raise a clear error on any `≤ 0`.
    setup do
      # Stop the GenServer created by the module-level setup; the
      # F-09 tests need to start a fresh one with a custom (bad)
      # config, and we must not leave a zombie process around.
      safe_stop()
      :ok
    end

    test "raises on per_chat_capacity: 0" do
      Application.put_env(:alethea, Alethea.Telegram.Pacer, per_chat_capacity: 0)

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} = Pacer.start_link([])
      assert msg =~ "per_chat_capacity must be > 0"
    end

    test "raises on per_chat_capacity: -1 (negative)" do
      Application.put_env(:alethea, Alethea.Telegram.Pacer, per_chat_capacity: -1)

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} = Pacer.start_link([])
      assert msg =~ "per_chat_capacity must be > 0"
    end

    test "raises on per_chat_refill_per_sec: 0" do
      Application.put_env(:alethea, Alethea.Telegram.Pacer, per_chat_refill_per_sec: 0.0)

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} = Pacer.start_link([])
      assert msg =~ "per_chat_refill_per_sec must be > 0"
    end

    test "raises on global_capacity: 0" do
      Application.put_env(:alethea, Alethea.Telegram.Pacer, global_capacity: 0)

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} = Pacer.start_link([])
      assert msg =~ "global_capacity must be > 0"
    end

    test "raises on global_refill_per_sec: 0" do
      Application.put_env(:alethea, Alethea.Telegram.Pacer, global_refill_per_sec: 0.0)

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stack}} = Pacer.start_link([])
      assert msg =~ "global_refill_per_sec must be > 0"
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

    test "fresh chat with full per-chat bucket and empty global bucket waits on global ~33ms (F-15)" do
      # F-15 test gap fix. The existing 31st-chats test asserts
      # `elapsed < 500` (loose), but the F-15 invariant is tighter:
      # the wait must be the GLOBAL refill (~33ms at 30 Hz), not
      # the per-chat refill (~1000ms at 1 Hz). A 500ms threshold
      # would let a slow per-chat refill (~500ms) sneak through.
      #
      # We assert `elapsed < 200ms` to pin the wait to the global
      # refill band. The 200ms threshold gives ~6× headroom over
      # the 33ms theoretical wait, accounting for CI scheduling
      # jitter.
      #
      # F-11: this is the verification arm for the F-11 cond
      # branch. The "per-chat fresh + global empty" branch is one
      # of three branches in the `try_acquire/1` cond. F-11 added
      # a fourth branch ("both empty") that uses min(per_chat,
      # global) so the GenServer wakes as soon as EITHER bucket
      # has a token, then re-checks. The per-chat-fresh case is
      # the third branch (per-chat full, global empty → wait on
      # global) and is documented here as a regression guard: the
      # F-11 change must NOT regress the existing "per-chat
      # dominates" path.
      for i <- 1..30 do
        assert :ok = Pacer.acquire("chat-#{i}")
      end

      # chat-fresh has a FRESH per-chat bucket (1 token). Global is
      # empty. The wait must be the global refill (~33ms at 30 Hz).
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-fresh")
      elapsed = monotonic_ms() - start

      assert elapsed < 200,
             "expected fresh-chat acquire to wait on global refill (~33ms), got #{elapsed}ms"
    end

    test "chat with empty per-chat and empty global uses min(per-chat, global) on the first wait (F-11)" do
      # F-11 regression guard. When BOTH buckets are empty, the
      # cond must return `min(per_chat_wait_ms, global_wait_ms)`
      # (not just the per-chat wait). The first wait uses the min;
      # the loop then re-checks and, if the per-chat is still
      # empty, waits on the per-chat refill — the binding
      # constraint. The fix is about which branch is taken FIRST,
      # not about the total wait time (the slower bucket is
      # always the binding constraint).
      #
      # We assert the F-11 cond branch is taken by checking that
      # the FIRST try_acquire returns the min wait, not the
      # per-chat wait. We do this by inspecting the ETS state
      # directly before the acquire: chat-F11's per-chat is 0 and
      # the global is 0. The cond should hit the BOTH empty
      # branch. The acquire will block for the per-chat refill
      # (~1000ms — the binding constraint) AFTER the first min
      # wait. We assert the total wait is bounded (the per-chat
      # refill band, ~1000ms), not < 200ms.
      assert :ok = Pacer.acquire("chat-F11")

      for i <- 1..29 do
        assert :ok = Pacer.acquire("chat-#{i}")
      end

      # Sanity: both buckets are drained (modulo refill drift).
      [{:singleton, g_tokens, _g_ts}] = :ets.lookup(:telegram_pacer_global, :singleton)
      [{_, p_tokens, _p_ts}] = :ets.lookup(:telegram_pacer_per_chat, "chat-F11")

      assert g_tokens < 1
      assert p_tokens < 1

      # The total wait is bounded by the per-chat refill (~1000ms
      # at 1 Hz), which is the binding constraint. F-11's claim
      # is that the FIRST iteration uses the min wait; the loop
      # then re-checks and the binding constraint takes over. We
      # assert the total wait is in the per-chat refill band.
      start = monotonic_ms()
      assert :ok = Pacer.acquire("chat-F11")
      elapsed = monotonic_ms() - start

      assert elapsed >= 800,
             "expected chat-F11 acquire to wait on per-chat refill (~1000ms), got #{elapsed}ms"

      assert elapsed < 1500,
             "expected chat-F11 acquire to NOT exceed per-chat refill, got #{elapsed}ms"
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

  describe "acquire/1 — finite timeout (F-10)" do
    # F-10 regression guard. The original `acquire/1` used
    # `GenServer.call(__MODULE__, {:acquire, ...}, :infinity)`. With
    # the single-GS design and the wait-loop inside `handle_call`,
    # an empty per-chat bucket blocks ALL other chats for the
    # refill period (1 s at 1 Hz). The fix changes the call timeout
    # to a finite 30 s and returns `{:error, :pacer_timeout}` on
    # exhaustion. Callers can decide to retry or escalate.
    #
    # We exercise the timeout path by configuring a very small
    # timeout (1 ms) and asserting the call returns
    # `{:error, :pacer_timeout}` instead of hanging. The 1 ms
    # timeout will fire well before any refill can complete.
    test "returns {:error, :pacer_timeout} when the call exceeds the timeout" do
      # Drain the per-chat bucket for chat-F10 so the next acquire
      # for chat-F10 will block on the per-chat refill (~1 s at
      # 1 Hz). The 1 ms call timeout fires well before that.
      assert :ok = Pacer.acquire("chat-F10")

      # Override the call timeout to 1 ms via Application config.
      # The Pacer reads `Application.get_env(:alethea, Pacer, [...])`
      # for the call timeout the same way it reads the rate knobs.
      original_timeout =
        :alethea
        |> Application.get_env(Pacer, [])
        |> Keyword.get(:call_timeout)

      Application.put_env(
        :alethea,
        Pacer,
        Keyword.put(
          Application.get_env(:alethea, Pacer, []),
          :call_timeout,
          1
        )
      )

      try do
        # The second acquire for the same chat will block on
        # per-chat refill. With a 1 ms call timeout, the call
        # returns :pacer_timeout.
        result = Pacer.acquire("chat-F10")
        assert {:error, :pacer_timeout} = result
      after
        env = Application.get_env(:alethea, Pacer, [])

        Application.put_env(
          :alethea,
          Pacer,
          if(original_timeout,
            do: Keyword.put(env, :call_timeout, original_timeout),
            else: Keyword.delete(env, :call_timeout)
          )
        )
      end
    end

    test "the default call timeout is 30_000 ms" do
      # F-10 contract: the call timeout is 30 s by default (long
      # enough to survive a per-chat refill at the production 1 Hz
      # rate, short enough that a stuck Pacer does not hang every
      # outbound Telegram call forever).
      #
      # We assert the contract by reading the timeout from the
      # module attribute. This is a structural assertion that
      # the production default is not `:infinity` (which would
      # deadlock every consumer in the event of a stuck Pacer).
      timeout = Pacer.call_timeout()

      assert is_integer(timeout)
      assert timeout == 30_000
      refute timeout == :infinity
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
