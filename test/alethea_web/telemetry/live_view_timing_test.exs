defmodule AletheaWeb.Telemetry.LiveViewTimingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AletheaWeb.Telemetry.LiveViewTiming

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    LiveViewTiming.attach()

    on_exit(fn ->
      LiveViewTiming.detach()
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  defp socket, do: %Phoenix.LiveView.Socket{view: AletheaWeb.DashboardLive}

  defp query(ms, queue_ms \\ 0) do
    :telemetry.execute(
      [:alethea, :repo, :query],
      %{
        total_time: System.convert_time_unit(ms + queue_ms, :millisecond, :native),
        query_time: System.convert_time_unit(ms, :millisecond, :native),
        queue_time: System.convert_time_unit(queue_ms, :millisecond, :native)
      },
      %{}
    )
  end

  # Start/stop are fed to the handler directly: emitting the real LiveView
  # events with a stub socket would crash Phoenix.LiveView.Logger's handler.
  defp span(stage, extra_meta, fun) do
    meta = Map.put(extra_meta, :socket, socket())
    LiveViewTiming.handle_event([:phoenix, :live_view, stage, :start], %{}, meta, nil)
    fun.()

    LiveViewTiming.handle_event(
      [:phoenix, :live_view, stage, :stop],
      %{duration: System.convert_time_unit(7, :millisecond, :native)},
      meta,
      nil
    )
  end

  test "logs mount duration with the queries run inside it" do
    log =
      capture_log([level: :info], fn ->
        span(:mount, %{}, fn ->
          query(3, 2)
          query(4)
        end)
      end)

    assert log =~ "liveview_timing stage=mount view=AletheaWeb.DashboardLive"
    assert log =~ "queries=2"
    assert log =~ "db_ms=9"
    assert log =~ "queue_ms=2"
    assert log =~ ~r/duration_ms=\d+/
  end

  test "names the event for handle_event and counts only its own queries" do
    query(5)

    log =
      capture_log([level: :info], fn ->
        span(:handle_event, %{event: "select_patient"}, fn -> query(1) end)
      end)

    assert log =~ "stage=handle_event view=AletheaWeb.DashboardLive event=\"select_patient\""
    assert log =~ "queries=1"
  end

  test "escapes and bounds the client-supplied event name" do
    forged = "a\nliveview_timing forged=1" <> String.duplicate("x", 500)

    log =
      capture_log([level: :info], fn ->
        LiveViewTiming.handle_event(
          [:phoenix, :live_view, :handle_event, :exception],
          %{duration: 1},
          %{socket: socket(), event: forged},
          nil
        )
      end)

    [line] = log |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "liveview_timing"))
    assert line =~ ~s(event="a\\nliveview_timing forged=1)
    assert line =~ "exception=true"
    refute line =~ String.duplicate("x", 200)
  end

  test "covers handle_params" do
    log = capture_log([level: :info], fn -> span(:handle_params, %{}, fn -> :ok end) end)

    assert log =~ "stage=handle_params view=AletheaWeb.DashboardLive"
    assert log =~ "queries=0"
  end

  test "queries outside a LiveView span are not counted or logged" do
    log = capture_log([level: :info], fn -> query(2) end)

    refute log =~ "liveview_timing"
  end
end
