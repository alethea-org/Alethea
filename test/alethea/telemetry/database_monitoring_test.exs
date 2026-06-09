defmodule Alethea.Telemetry.DatabaseMonitoringTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Alethea.Telemetry.DatabaseMonitoring

  @query_event [:alethea, :repo, :query]
  @connection_error_event [:db_connection, :connection_error]
  @pool_saturation_event [:alethea, :repo, :pool, :saturation]
  @repo_connection_error_event [:alethea, :repo, :connection, :error]

  @config [
    enabled: true,
    slow_query_threshold_ms: 1_000,
    pool_queue_warn_ms: 100,
    pool_queue_length_warn: 1,
    query_log_max_chars: 4_000
  ]

  setup do
    previous_config = Application.get_env(:alethea, :database_monitoring)

    Application.put_env(:alethea, :database_monitoring, @config)
    DatabaseMonitoring.attach()

    on_exit(fn ->
      if previous_config do
        Application.put_env(:alethea, :database_monitoring, previous_config)
      else
        Application.delete_env(:alethea, :database_monitoring)
      end

      DatabaseMonitoring.attach()
    end)

    :ok
  end

  test "does not warn for queries under the slow query threshold" do
    log =
      capture_log(fn ->
        :telemetry.execute(
          @query_event,
          %{total_time: native_ms(900), query_time: native_ms(900)},
          query_metadata()
        )
      end)

    refute log =~ "slow database query"
  end

  test "logs slow queries with SQL and timings without params" do
    metadata =
      query_metadata(%{
        query: "SELECT * FROM professionals WHERE email = $1",
        params: ["classified-secret"]
      })

    log =
      capture_log(fn ->
        :telemetry.execute(
          @query_event,
          %{
            total_time: native_ms(1_250),
            query_time: native_ms(900),
            queue_time: native_ms(250),
            decode_time: native_ms(100)
          },
          metadata
        )
      end)

    assert log =~ "slow database query"
    assert log =~ "SELECT * FROM professionals WHERE email = $1"
    assert log =~ "total_time=1250.0ms"
    assert log =~ "query_time=900.0ms"
    assert log =~ "queue_time=250.0ms"
    refute log =~ "classified-secret"
  end

  test "logs high queue time and emits pool saturation telemetry" do
    attach_test_handler(:pool_saturation, @pool_saturation_event)

    log =
      capture_log(fn ->
        :telemetry.execute(
          @query_event,
          %{
            total_time: native_ms(180),
            query_time: native_ms(30),
            queue_time: native_ms(150)
          },
          query_metadata()
        )
      end)

    assert log =~ "database pool queue delay"
    assert log =~ "queue_time=150.0ms"

    assert_receive {:pool_saturation, %{count: 1}, %{reason: :queue_time, queue_time_ms: 150.0}}
  end

  test "logs connection checkout errors clearly and emits connection error telemetry" do
    attach_test_handler(:connection_error, @repo_connection_error_event)

    error =
      DBConnection.ConnectionError.exception(
        "connection not available and request was dropped from queue after 1000ms"
      )

    log =
      capture_log(fn ->
        :telemetry.execute(
          @connection_error_event,
          %{count: 1},
          %{error: error, opts: [timeout: 1_000, password: "classified-secret"]}
        )
      end)

    assert log =~ "DB connection timeout/check-out failure"
    assert log =~ "connection not available"
    assert log =~ "timeout: 1000"
    refute log =~ "classified-secret"

    assert_receive {:connection_error, %{count: 1},
                    %{error: error_message, opts: [timeout: 1_000]}}

    assert error_message =~ "connection not available"
  end

  test "telemetry metrics expose pool saturation and connection counters" do
    metric_names =
      AletheaWeb.Telemetry.metrics()
      |> Enum.map(&Enum.join(&1.name, "."))

    assert "alethea.repo.pool.metrics.checkout_queue_length" in metric_names
    assert "alethea.repo.pool.metrics.ready_conn_count" in metric_names
    assert "alethea.repo.pool.saturation.count" in metric_names
    assert "alethea.repo.connection.error.count" in metric_names
  end

  defp query_metadata(overrides \\ %{}) do
    Map.merge(
      %{
        repo: Alethea.Repo,
        source: "professionals",
        query: "SELECT 1",
        params: [],
        result: {:ok, %{}}
      },
      overrides
    )
  end

  defp native_ms(ms) do
    System.convert_time_unit(ms, :millisecond, :native)
  end

  defp attach_test_handler(message_tag, event) do
    handler_id = {__MODULE__, message_tag, self()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_test_event/4,
        {test_pid, message_tag}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_test_event(_event, measurements, metadata, {test_pid, message_tag}) do
    send(test_pid, {message_tag, measurements, metadata})
  end
end
