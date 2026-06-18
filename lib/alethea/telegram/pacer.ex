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

  The ETS tables are `:protected` and `:named_table`. `:protected`
  access means reads are allowed from any process, but writes are
  allowed ONLY from the table owner (the GenServer). This enforces
  the moduledoc claim that "writes go through the GenServer only" —
  a foreign process cannot silently corrupt the bucket state. The
  `Pacer.inspect_per_chat/0` and `Pacer.inspect_global/0` accessors
  are the canonical read path for ops dashboards; they go through
  the GenServer for consistency with the redaction rules.

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

  # F-10: finite call timeout. The previous `:infinity` combined with
  # the single-GS design and the wait-loop inside `handle_call` meant
  # a single chat's empty bucket could block ALL other chats for the
  # refill period (1 s at 1 Hz per-chat), and a stuck Pacer would
  # deadlock every consumer forever. 30 s is the new default — long
  # enough to survive a per-chat refill at the production 1 Hz rate,
  # short enough that a stuck Pacer does not hang every outbound
  # Telegram call. Callers receive `{:error, :pacer_timeout}` and can
  # decide to retry or escalate.
  @default_call_timeout 30_000

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

  ## Timeout (F-10)

  The call uses a **finite** timeout (30 s by default; configurable
  via `:call_timeout` in `Application.get_env(:alethea, Pacer, [...])`).
  On timeout exhaustion the call returns `{:error, :pacer_timeout}`
  rather than blocking forever. Callers can decide to retry or
  escalate. A stuck Pacer does not deadlock every consumer.

  Cross-chat blocking is still possible within a single in-flight
  call (the GenServer is single-threaded), but the wait is bounded
  by the call timeout, not by `:infinity`.
  """
  @spec acquire(String.t()) :: :ok | {:error, :pacer_timeout}
  def acquire(chat_id_hash) when is_binary(chat_id_hash) and byte_size(chat_id_hash) == 64 do
    # F-14: the guard requires `byte_size(chat_id_hash) == 64`,
    # matching the ChatIdHash output shape (HMAC-SHA256 hex = 64
    # chars). The previous `is_binary(chat_id_hash)` guard accepted
    # the empty string `""`, which allowed callers to silently
    # rate-limit every "empty chat" together (a noisy neighbor
    # problem). A missing or malformed chat_id_hash now raises
    # `FunctionClauseError` instead of silently consuming tokens.
    #
    # F-10: `GenServer.call/3` raises `:exit` on timeout (not an
    # exception), so `try/rescue` does not catch it. We must use
    # `try/catch :exit, _` to convert the timeout into a clean
    # `{:error, :pacer_timeout}` return value.
    try do
      GenServer.call(__MODULE__, {:acquire, chat_id_hash}, call_timeout())
    catch
      :exit, {:timeout, _} -> {:error, :pacer_timeout}
    end
  end

  @doc """
  Returns the configured call timeout in milliseconds (F-10).

  Reads from `Application.get_env(:alethea, Pacer, [...])` with a
  30_000 ms default. Exposed as a public function so tests can assert
  the production default is not `:infinity` (a structural guarantee
  that the Pacer cannot deadlock every consumer).
  """
  @spec call_timeout() :: pos_integer()
  def call_timeout do
    :alethea
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:call_timeout, @default_call_timeout)
  end

  @doc """
  Returns a serializable snapshot of the per-chat bucket table
  (F-12 accessor). Goes through the GenServer for consistency with
  the redaction rules in `format_status/2`. The map is keyed by
  `chat_id_hash`; each value is `%{tokens: float, last_refill_ms: integer}`.
  """
  @spec inspect_per_chat() :: %{
          optional(String.t()) => %{tokens: float(), last_refill_ms: integer()}
        }
  def inspect_per_chat do
    GenServer.call(__MODULE__, :inspect_per_chat)
  end

  @doc """
  Returns a serializable snapshot of the global bucket table
  (F-12 accessor). Goes through the GenServer for consistency with
  the redaction rules in `format_status/2`.
  """
  @spec inspect_global() :: %{tokens: float(), last_refill_ms: integer()}
  def inspect_global do
    GenServer.call(__MODULE__, :inspect_global)
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    # F-09: validate all four config knobs at boot. A 0 or negative
    # value would brick the Pacer — `do_acquire/1` enters an infinite
    # loop on the `{:wait, _non_positive}` branch because
    # `ms_until_next_token/2` returns 1 ms forever. Mirrors the
    # `BotToken.init/1` fail-loud pattern: a misconfiguration must
    # crash the supervisor, not silently throttle every Telegram
    # message to "wait 1 ms, then check again".
    validate_positive!(:per_chat_capacity, per_chat_capacity())
    validate_positive!(:per_chat_refill_per_sec, per_chat_refill_per_sec())
    validate_positive!(:global_capacity, global_capacity())
    validate_positive!(:global_refill_per_sec, global_refill_per_sec())

    create_table(@table_per_chat)
    create_table(@table_global)

    {:ok, %{}}
  end

  defp validate_positive!(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive!(_name, value) when is_float(value) and value > 0, do: :ok

  defp validate_positive!(name, value) do
    raise ArgumentError,
          "Alethea.Telegram.Pacer: #{name} must be > 0 (got #{inspect(value)}). " <>
            "A 0 or negative value bricks the Pacer (infinite-loop in do_acquire/1)."
  end

  @impl true
  def handle_call({:acquire, chat_id_hash}, _from, state) do
    case do_acquire(chat_id_hash) do
      :acquired -> {:reply, :ok, state}
      :timed_out -> {:reply, {:error, :pacer_timeout}, state}
    end
  end

  # F-12: the GenServer is the table owner, so the inspector reads
  # are done inside `handle_call`. The snapshot is a plain map
  # (serializable for ops dashboards).
  def handle_call(:inspect_per_chat, _from, state) do
    rows = :ets.tab2list(@table_per_chat)

    snapshot =
      Map.new(rows, fn {key, tokens, last_refill_ms} ->
        {key, %{tokens: tokens, last_refill_ms: last_refill_ms}}
      end)

    {:reply, snapshot, state}
  end

  def handle_call(:inspect_global, _from, state) do
    case :ets.lookup(@table_global, :singleton) do
      [] ->
        {:reply, %{tokens: 0, last_refill_ms: 0}, state}

      [{:singleton, tokens, last_refill_ms}] ->
        {:reply, %{tokens: tokens, last_refill_ms: last_refill_ms}, state}
    end
  end

  ## Private

  defp create_table(name) do
    if :ets.info(name) == :undefined do
      :ets.new(name, [
        :set,
        :named_table,
        :protected,
        {:read_concurrency, true}
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
  # The loop is bounded by the GenServer.call timeout (30 s by
  # default; see `call_timeout/0`); on timeout exhaustion the call
  # returns `:timed_out` to the caller, who receives
  # `{:error, :pacer_timeout}` from `acquire/1`. A sustained overload
  # does NOT block the caller forever.
  defp do_acquire(chat_id_hash) do
    case try_acquire(chat_id_hash) do
      :ok ->
        :acquired

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
  #
  # F-11: when BOTH buckets are empty, return
  # `min(per_chat_wait_ms, global_wait_ms)` so the GenServer wakes
  # as soon as EITHER bucket has a token, then re-checks both. The
  # previous implementation waited on the per-chat refill (~1000ms
  # at 1 Hz) even when the global refill (~33ms at 30 Hz) would
  # have unblocked the acquire sooner — a 30× slowdown on the
  # common "thundering herd" case.
  defp try_acquire(chat_id_hash) do
    per_chat_state = refill_per_chat_bucket(chat_id_hash)
    global_state = refill_global_bucket()

    cond do
      per_chat_state.tokens >= 1 and global_state.tokens >= 1 ->
        consume_per_chat(chat_id_hash)
        consume_global()
        :ok

      per_chat_state.tokens < 1 and global_state.tokens < 1 ->
        per_chat_wait = ms_until_next_token(per_chat_state, per_chat_refill_per_sec())
        global_wait = ms_until_next_token(global_state, global_refill_per_sec())
        {:wait, min(per_chat_wait, global_wait)}

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
