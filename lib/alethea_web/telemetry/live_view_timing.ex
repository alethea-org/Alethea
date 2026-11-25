defmodule AletheaWeb.Telemetry.LiveViewTiming do
  @moduledoc """
  Logs how long each LiveView `mount`, `handle_params` and `handle_event`
  takes, together with the number of Repo queries it ran and the time they
  spent in the database and waiting for a pool connection.

  Ecto emits `[:alethea, :repo, :query]` in the calling process, so queries
  are attributed to the LiveView stage running in that same process. The
  `on_mount` hooks run inside the `mount` span and are included in it.

  One line per stage, at `:info`:

      liveview_timing stage=mount view=AletheaWeb.DashboardLive duration_ms=412 queries=14 db_ms=380 queue_ms=3

  `db_ms` is the queries' total time and includes `queue_ms`.
  """

  require Logger

  @handler_id "alethea-liveview-timing"
  @stages [:mount, :handle_params, :handle_event]
  @query_event [:alethea, :repo, :query]
  @acc_key {__MODULE__, :acc}
  @event_name_limit 64

  def attach do
    events =
      [@query_event] ++
        for stage <- @stages, phase <- [:start, :stop, :exception] do
          [:phoenix, :live_view, stage, phase]
        end

    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)
  end

  def detach, do: :telemetry.detach(@handler_id)

  def handle_event([:phoenix, :live_view, _stage, :start], _measurements, _metadata, _config) do
    Process.put(@acc_key, %{queries: 0, db: 0, queue: 0})
    :ok
  end

  def handle_event(@query_event, measurements, _metadata, _config) do
    case Process.get(@acc_key) do
      %{} = acc ->
        Process.put(@acc_key, %{
          queries: acc.queries + 1,
          db: acc.db + (measurements[:total_time] || 0),
          queue: acc.queue + (measurements[:queue_time] || 0)
        })

      nil ->
        :ok
    end

    :ok
  end

  def handle_event([:phoenix, :live_view, stage, phase], measurements, metadata, _config)
      when phase in [:stop, :exception] do
    acc = Process.delete(@acc_key) || %{queries: 0, db: 0, queue: 0}

    Logger.info(fn ->
      [
        "liveview_timing stage=#{stage} view=#{view_name(metadata)}",
        event_part(metadata),
        " duration_ms=#{to_ms(measurements[:duration])}",
        " queries=#{acc.queries} db_ms=#{to_ms(acc.db)} queue_ms=#{to_ms(acc.queue)}",
        if(phase == :exception, do: " exception=true", else: "")
      ]
    end)

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp view_name(%{socket: %{view: view}}) when is_atom(view) and not is_nil(view),
    do: inspect(view)

  defp view_name(_metadata), do: "unknown"

  # The event name comes from the client: inspect/2 escapes control
  # characters (no forged log lines) and the limit bounds its length.
  defp event_part(%{event: event}) when is_binary(event),
    do: " event=" <> inspect(event, printable_limit: @event_name_limit)

  defp event_part(_metadata), do: ""

  defp to_ms(nil), do: 0
  defp to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
