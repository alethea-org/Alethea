defmodule Alethea.Telegram.Pacer do
  @moduledoc """
  Outbound rate-limit primitive for the Telegram channel (C-7).

  The Pacer is a single named GenServer (`:telegram_pacer`) holding
  two ETS-backed TokenBuckets:

  - `:telegram_pacer_per_chat` — one bucket per `chat_id_hash`,
    refill `per_chat_refill_per_sec` Hz, capacity `per_chat_capacity`
    tokens (production: 1 token / 1 Hz, matching Telegram's per-chat
    rate limit of "1 message per second per chat").

  - `:telegram_pacer_global` — single bucket, refill
    `global_refill_per_sec` Hz, capacity `global_capacity` tokens
    (production: 30 tokens / 30 Hz, matching Telegram's global
    rate limit of "30 messages per second globally").

  ## Why a single GenServer (not just ETS)

  The acquire path needs to (a) refill both buckets based on elapsed
  time, (b) check both, and (c) consume one token from each atomically.
  ETS `:set` lookup is atomic, but the read-refill-write sequence
  across two tables is not — a concurrent caller could observe a
  stale refill state. The GenServer serialises the acquire path so
  the two buckets stay consistent under concurrent Telegram traffic.

  The ETS tables are `:public` and `:named_table` so the buckets can
  be inspected (read-only) by future ops dashboards without going
  through the GenServer. Writes go through the GenServer only.

  ## Why a `Process.sleep/1` inside `handle_call`

  When a bucket is empty, the call blocks in the GenServer's process
  until the next refill. The alternative — returning `{:wait, ms}` to
  the caller — pushes the wait-loop into every consumer (`outbound
  worker`, `client.req` impl, future bots). Centralising the wait in
  the GenServer keeps the consumer code one-liner-shaped
  (`Pacer.acquire(chat_id_hash)` → `:ok`).

  ## Configuration

  All four knobs are read at acquire-time from
  `Application.get_env(:alethea, Alethea.Telegram.Pacer, defaults)`:

  - `:per_chat_capacity` (default `1`)
  - `:per_chat_refill_per_sec` (default `1.0`)
  - `:global_capacity` (default `30`)
  - `:global_refill_per_sec` (default `30.0`)

  The defaults match Telegram's published limits. Tests can override
  any knob in `setup` blocks.

  See `openspec/sdd/telegram-paciente-foundation/specs/C-7-outbound-rate-limit/spec.md`
  for the full requirement set.
  """

  use GenServer

  @table_per_chat :telegram_pacer_per_chat
  @table_global :telegram_pacer_global

  # Production defaults — Telegram's published limits.
  @default_per_chat_capacity 1
  @default_per_chat_refill_per_sec 1.0
  @default_global_capacity 30
  @default_global_refill_per_sec 30.0

  ## Public API

  @doc """
  Starts the Pacer GenServer and creates the two named ETS tables.
  """
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires a token from the per-chat bucket AND the global bucket
  for `chat_id_hash`, blocking if either bucket is empty. Returns
  `:ok` once both buckets have a token to spare.

  The per-chat limit dominates over the global limit: if the per-chat
  bucket is empty, the call blocks at the per-chat refill rate,
  regardless of how many tokens the global bucket has.
  """
  @spec acquire(String.t()) :: :ok
  def acquire(chat_id_hash) when is_binary(chat_id_hash) do
    GenServer.call(__MODULE__, {:acquire, chat_id_hash}, :infinity)
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    create_table(@table_per_chat)
    create_table(@table_global)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, chat_id_hash}, _from, state) do
    do_acquire(chat_id_hash)
    {:reply, :ok, state}
  end

  ## Private

  defp create_table(name) do
    if :ets.info(name) == :undefined do
      :ets.new(name, [
        :set,
        :named_table,
        :public,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])
    end

    :ok
  end

  # Reads the configurable knobs with production defaults. Pulled out
  # so test overrides via `Application.put_env(:alethea, Alethea.Telegram.Pacer, ...)`
  # are honored at acquire-time, not just at boot.
  defp per_chat_capacity, do: config(:per_chat_capacity, @default_per_chat_capacity)

  defp per_chat_refill_per_sec,
    do: config(:per_chat_refill_per_sec, @default_per_chat_refill_per_sec)

  defp global_capacity, do: config(:global_capacity, @default_global_capacity)
  defp global_refill_per_sec, do: config(:global_refill_per_sec, @default_global_refill_per_sec)

  defp config(key, default) do
    :alethea
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  # The acquire loop. Both buckets must have at least one token; if
  # either is empty, we sleep until the next refill and try again.
  # The loop is intentionally bounded by the GenServer.call timeout
  # (`:infinity` from `acquire/1`), so a sustained overload waits
  # forever rather than dropping the message.
  defp do_acquire(chat_id_hash) do
    case try_acquire(chat_id_hash) do
      :ok ->
        :ok

      {:wait, wait_ms} when wait_ms > 0 ->
        Process.sleep(wait_ms)
        do_acquire(chat_id_hash)

      {:wait, _non_positive} ->
        # Defensive: a non-positive wait means the buckets are right
        # at the boundary. Retry once more — the next refill tick is
        # within microseconds.
        do_acquire(chat_id_hash)
    end
  end

  # Attempts a single acquire. Returns `:ok` if both buckets have a
  # token; otherwise `{:wait, ms}` where `ms` is the time (in ms)
  # until the next refill on the *dominant* empty bucket.
  defp try_acquire(chat_id_hash) do
    per_chat_state = refill_per_chat_bucket(chat_id_hash)
    global_state = refill_global_bucket()

    cond do
      per_chat_state.tokens >= 1 and global_state.tokens >= 1 ->
        consume_per_chat(chat_id_hash)
        consume_global()
        :ok

      per_chat_state.tokens < 1 ->
        {:wait, ms_until_next_token(per_chat_state, per_chat_refill_per_sec())}

      true ->
        {:wait, ms_until_next_token(global_state, global_refill_per_sec())}
    end
  end

  ## Per-chat bucket

  defp refill_per_chat_bucket(chat_id_hash) do
    now = monotonic_ms()
    refill(@table_per_chat, chat_id_hash, per_chat_capacity(), per_chat_refill_per_sec(), now)
  end

  defp consume_per_chat(chat_id_hash) do
    [{_, tokens, _ts}] = :ets.lookup(@table_per_chat, chat_id_hash)
    :ets.insert(@table_per_chat, {chat_id_hash, tokens - 1, monotonic_ms()})
  end

  ## Global bucket

  defp refill_global_bucket do
    now = monotonic_ms()
    refill(@table_global, :singleton, global_capacity(), global_refill_per_sec(), now)
  end

  defp consume_global do
    [{_, tokens, _ts}] = :ets.lookup(@table_global, :singleton)
    :ets.insert(@table_global, {:singleton, tokens - 1, monotonic_ms()})
  end

  ## Bucket mechanics

  # Token-bucket refill math (continuous):
  #
  #   tokens_new = min(capacity, tokens_old + elapsed_ms * refill_per_sec / 1000)
  #
  # The ETS row shape is `{key, tokens, last_refill_ms}`. We update
  # the timestamp on every refill so the next refill can compute the
  # elapsed delta correctly.
  defp refill(table, key, capacity, refill_per_sec, now_ms) do
    case :ets.lookup(table, key) do
      [] ->
        # First time we see this key: bucket starts FULL.
        :ets.insert(table, {key, capacity, now_ms})
        %{tokens: capacity}

      [{^key, tokens, last_refill_ms}] ->
        elapsed_ms = max(0, now_ms - last_refill_ms)
        gained = elapsed_ms * refill_per_sec / 1000.0
        new_tokens = min(capacity, tokens + gained)
        :ets.insert(table, {key, new_tokens, now_ms})
        %{tokens: new_tokens}
    end
  end

  # How long (in ms) until `state.tokens` reaches 1 token at the given
  # refill rate (tokens/sec)? If we already have ≥ 1, return 0;
  # otherwise compute the wait. The refill rate is passed explicitly
  # so the per-chat and global wait calculations stay independent —
  # we don't want a per-chat-empty wait to be charged at the global
  # refill rate (or vice versa).
  defp ms_until_next_token(%{tokens: tokens}, _rate) when tokens >= 1, do: 0

  defp ms_until_next_token(%{tokens: tokens}, rate) when rate > 0 do
    # (1 - tokens) tokens needed, at `rate` tokens/sec.
    # Convert to ms. Always returns at least 1 ms so `Process.sleep/1`
    # actually yields; a 0 ms sleep can spin.
    max(1, ceil((1.0 - tokens) * 1000.0 / rate))
  end

  defp ms_until_next_token(_state, _rate), do: 1

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
