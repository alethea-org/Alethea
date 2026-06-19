defmodule Alethea.Telegram.Client.Fake do
  @moduledoc """
  Test/dev adapter for `Alethea.Telegram.Client` (C-7 outbound, PR #2).

  A no-op `send_message/2` that records every call in an in-memory
  ETS table so tests can assert on the outbound flow without hitting
  the Telegram Bot API. The table is owned by a `GenServer` (the
  process is registered under the module name) so concurrent calls
  serialize through a single writer — the table is `:protected` so
  only the GenServer can write, but any process can read.

  ## When to use

    - All `Alethea.Jobs.TelegramOutboundWorker` tests (PR #3a) —
      assert on `sends/0` to verify the worker called
      `send_message/2` with the right `chat_id` and `text`.
    - Local `:dev` runs without a real Telegram bot — sends
      accumulate in the table and are visible via `sends/0` from
      an `iex` session.
    - Default fallback if `config :alethea, :telegram_client` is
      not set — a missing config degrades to this no-op adapter,
      NOT a runtime crash.

  ## Out of scope

  The production `Req` adapter (`Alethea.Telegram.Client.Req`) lands
  in PR #3a. This file is the test/dev no-op.

  ## Why a GenServer (not just an ETS table)

  A bare `:ets.new/2` would work for read-mostly test access, but
  the `send_message/2` callback needs to INSERT into the table
  under the table's `:protected` access. Wrapping the table in a
  GenServer is the canonical Phoenix pattern for a single-writer
  resource and gives us `:ok, id` semantics (the Fake returns a
  pseudo-random `message_id` so tests can assert on a non-nil id
  if they need to).
  """

  use GenServer

  @behaviour Alethea.Telegram.Client

  alias Alethea.Telegram.Client

  @table :telegram_fake_client_sends

  # --- Public API ---

  @doc """
  Sends a message. The Fake records the call in ETS and returns
  `{:ok, id}` with a pseudo-random `message_id` (a positive
  integer in the range `[1, 2^31 - 1]`). The id is unique per
  send but otherwise meaningless — tests can use it to assert on
  a non-nil id.
  """
  @impl Client
  def send_message(chat_id, text)
      when is_integer(chat_id) and chat_id > 0 and is_binary(text) do
    GenServer.call(__MODULE__, {:send, chat_id, text})
  end

  def send_message(chat_id, text) do
    # Defensive clause — the behaviour does not require a guard, but
    # the Fake rejects malformed input loudly so a caller bug
    # surfaces as a runtime error rather than a silent skip.
    _ = {chat_id, text}

    raise ArgumentError,
          "Alethea.Telegram.Client.Fake.send_message/2 expects (positive_integer, binary), got (#{inspect(chat_id)}, #{inspect(text)})"
  end

  @doc """
  Returns the list of all sends recorded so far, in insertion order.
  Each entry is `%{chat_id: pos_integer, text: binary, message_id: pos_integer}`.

  Used by tests to assert on the outbound flow without a real
  Telegram call. The list is a snapshot — subsequent sends do not
  retroactively modify it.
  """
  @spec sends() :: [%{chat_id: pos_integer(), text: String.t(), message_id: pos_integer()}]
  def sends do
    GenServer.call(__MODULE__, :sends)
  end

  @doc """
  Clears the recorded sends. Tests call this in `setup` to ensure
  hermetic state.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # --- GenServer ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    state =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [
            :set,
            :named_table,
            :protected,
            {:read_concurrency, true}
          ])

        _ ->
          :ets.delete_all_objects(@table)
          @table
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:send, chat_id, text}, _from, state) do
    message_id = :rand.uniform(2_147_483_647)
    :ets.insert(state, {message_id, chat_id, text})
    {:reply, {:ok, message_id}, state}
  end

  def handle_call(:sends, _from, state) do
    rows = :ets.tab2list(state)

    sends =
      Enum.map(rows, fn {message_id, chat_id, text} ->
        %{message_id: message_id, chat_id: chat_id, text: text}
      end)

    {:reply, sends, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state)
    {:reply, :ok, state}
  end
end
