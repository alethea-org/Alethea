defmodule Alethea.RateLimiter do
  @moduledoc """
  ETS-based rate limiter for WhatsApp webhook.
  Limits to max 10 messages per phone hash per minute.
  """

  use GenServer

  @table_name :whatsapp_rate_limit
  @max_requests 10
  @window_seconds 60

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Check if a phone_hash is rate limited.
  Returns :ok if allowed, {:error, :rate_limited} if not.
  """
  def check(phone_hash) do
    # Use try/catch for ETS access since this is called from Controller (not GenServer)
    try do
      case :ets.lookup(@table_name, phone_hash) do
        [] ->
          # No existing entry, allow and create new
          insert_new(phone_hash)
          :ok

        [{^phone_hash, count, timestamp}] ->
          elapsed = System.system_time(:second) - timestamp

          if elapsed < @window_seconds do
            if count >= @max_requests do
              {:error, :rate_limited}
            else
              increment(phone_hash, count)
              :ok
            end
          else
            # Window expired, reset
            insert_new(phone_hash)
            :ok
          end

        _ ->
          # Unexpected format, allow
          :ok
      end
    rescue
      # ETS not available or other error, allow request
      _ -> :ok
    end
  end

  @doc """
  Get current rate limit status for a phone_hash.
  """
  def status(phone_hash) do
    try do
      case :ets.lookup(@table_name, phone_hash) do
        [] ->
          %{remaining: @max_requests, reset_in: @window_seconds}

        [{^phone_hash, count, timestamp}] ->
          elapsed = System.system_time(:second) - timestamp

          if elapsed < @window_seconds do
            %{
              remaining: max(0, @max_requests - count),
              reset_in: @window_seconds - elapsed
            }
          else
            %{remaining: @max_requests, reset_in: 0}
          end

        _ ->
          %{remaining: @max_requests, reset_in: @window_seconds}
      end
    rescue
      _ -> %{remaining: @max_requests, reset_in: 0}
    end
  end

  # Private functions

  defp insert_new(phone_hash) do
    :ets.insert(@table_name, {phone_hash, 1, System.system_time(:second)})
  end

  defp increment(phone_hash, count) do
    :ets.insert(@table_name, {phone_hash, count + 1, System.system_time(:second)})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table_opts = [
      :set,
      :named_table,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ]

    :ets.new(@table_name, table_opts)

    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean up old entries periodically
    cleanup_old_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    # Clean up every 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end

  defp cleanup_old_entries do
    now = System.system_time(:second)
    cutoff = now - @window_seconds

    # Get all keys and filter out old ones
    case :ets.match(@table_name, :"$1") do
      :undefined ->
        :ok

      entries when is_list(entries) ->
        Enum.each(entries, fn [key, _count, timestamp] ->
          if timestamp < cutoff do
            :ets.delete(@table_name, key)
          end
        end)
    end
  end

  @doc """
  Clear all rate limit entries (for testing).
  """
  def clear_all do
    :ets.delete_all_objects(@table_name)
  end
end
