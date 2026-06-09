defmodule Alethea.Telemetry.DatabaseMonitoring do
  @moduledoc """
  Logs database health signals from Ecto and DBConnection telemetry events.
  """

  require Logger

  @handler_id "alethea-database-monitoring"
  @query_event [:alethea, :repo, :query]
  @connection_error_event [:db_connection, :connection_error]
  @pool_metrics_event [:alethea, :repo, :pool, :metrics]
  @pool_saturation_event [:alethea, :repo, :pool, :saturation]
  @repo_connection_error_event [:alethea, :repo, :connection, :error]

  @defaults [
    enabled: true,
    slow_query_threshold_ms: 1_000,
    pool_queue_warn_ms: 100,
    pool_queue_length_warn: 1,
    query_log_max_chars: 4_000
  ]

  @safe_pool_opts [:queue, :queue_target, :queue_interval, :timeout, :pool_timeout]

  def attach do
    config = config()

    if Keyword.fetch!(config, :enabled) do
      attach_handlers(config)
    else
      :telemetry.detach(@handler_id)
      :ok
    end
  end

  def handle_event(@query_event, measurements, metadata, config) do
    config = normalize_config(config)

    if Keyword.fetch!(config, :enabled) do
      maybe_log_slow_query(measurements, metadata, config)
      maybe_log_pool_queue_delay(measurements, metadata, config)
    end

    :ok
  end

  def handle_event(@connection_error_event, measurements, metadata, config) do
    config = normalize_config(config)

    if Keyword.fetch!(config, :enabled) do
      emit_connection_error_metric(measurements, metadata)
      log_connection_error(metadata, config)
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  def emit_pool_metrics do
    config = config()

    with true <- Keyword.fetch!(config, :enabled),
         {:ok, pool, pool_module} <- repo_pool() do
      pool
      |> DBConnection.get_connection_metrics(pool: pool_module)
      |> normalize_pool_metrics()
      |> Enum.each(&emit_pool_metric(&1, config))
    else
      _ -> :ok
    end
  catch
    :exit, reason ->
      Logger.warning("database pool metrics collection failed: reason=#{inspect(reason)}")
      :ok
  end

  defp repo_pool do
    repo = Alethea.Repo.get_dynamic_repo()
    %{pid: pool, opts: opts} = Ecto.Adapter.lookup_meta(repo)

    {:ok, pool, Keyword.get(opts, :pool, DBConnection.ConnectionPool)}
  rescue
    _ -> :error
  catch
    :exit, _reason -> :error
  end

  defp normalize_pool_metrics({:ok, metrics}), do: metrics
  defp normalize_pool_metrics(metrics) when is_list(metrics), do: metrics
  defp normalize_pool_metrics(_metrics), do: []

  defp attach_handlers(config) do
    case :telemetry.attach_many(
           @handler_id,
           [@query_event, @connection_error_event],
           &__MODULE__.handle_event/4,
           config
         ) do
      :ok ->
        :ok

      {:error, :already_exists} ->
        :telemetry.detach(@handler_id)

        :telemetry.attach_many(
          @handler_id,
          [@query_event, @connection_error_event],
          &__MODULE__.handle_event/4,
          config
        )
    end
  end

  defp config do
    @defaults
    |> Keyword.merge(Application.get_env(:alethea, :database_monitoring, []))
    |> normalize_config()
  end

  defp normalize_config(config) when is_map(config) do
    config
    |> Map.to_list()
    |> normalize_config()
  end

  defp normalize_config(config) when is_list(config) do
    Keyword.merge(@defaults, config)
  end

  defp maybe_log_slow_query(measurements, metadata, config) do
    total_time = total_time(measurements)
    total_ms = native_to_ms(total_time)
    threshold_ms = Keyword.fetch!(config, :slow_query_threshold_ms)

    if total_ms > threshold_ms do
      Logger.warning(
        slow_query_message(total_ms, measurements, metadata, config),
        query_metadata(total_ms, measurements, metadata)
      )
    end
  end

  defp maybe_log_pool_queue_delay(measurements, metadata, config) do
    queue_time = Map.get(measurements, :queue_time, 0)
    queue_ms = native_to_ms(queue_time)
    threshold_ms = Keyword.fetch!(config, :pool_queue_warn_ms)

    if queue_ms > threshold_ms do
      emit_pool_saturation(%{reason: :queue_time, queue_time_ms: queue_ms}, metadata)

      Logger.warning(
        pool_queue_delay_message(queue_ms, threshold_ms, metadata),
        repo_metadata(metadata, queue_time_ms: queue_ms, threshold_ms: threshold_ms)
      )
    end
  end

  defp emit_pool_metric(metric, config) do
    checkout_queue_length = Map.get(metric, :checkout_queue_length, 0)
    ready_conn_count = Map.get(metric, :ready_conn_count, 0)
    source = Map.get(metric, :source)

    :telemetry.execute(
      @pool_metrics_event,
      %{
        checkout_queue_length: checkout_queue_length,
        ready_conn_count: ready_conn_count
      },
      %{repo: Alethea.Repo, source: inspect(source)}
    )

    threshold = Keyword.fetch!(config, :pool_queue_length_warn)

    if checkout_queue_length >= threshold do
      metadata = %{repo: Alethea.Repo, source: inspect(source)}

      emit_pool_saturation(
        %{
          reason: :checkout_queue_length,
          checkout_queue_length: checkout_queue_length,
          ready_conn_count: ready_conn_count
        },
        metadata
      )

      Logger.warning(
        "database pool saturation: checkout_queue_length=#{checkout_queue_length} " <>
          "ready_conn_count=#{ready_conn_count} threshold=#{threshold} source=#{inspect(source)}",
        repo_metadata(metadata,
          checkout_queue_length: checkout_queue_length,
          ready_conn_count: ready_conn_count,
          threshold: threshold
        )
      )
    end
  end

  defp emit_pool_saturation(extra_metadata, metadata) do
    :telemetry.execute(
      @pool_saturation_event,
      %{count: 1},
      Map.merge(%{repo: metadata[:repo], source: metadata[:source]}, extra_metadata)
    )
  end

  defp emit_connection_error_metric(measurements, metadata) do
    count = Map.get(measurements, :count, 1)

    :telemetry.execute(
      @repo_connection_error_event,
      %{count: count},
      %{
        repo: Alethea.Repo,
        error: format_error(metadata[:error], 4_000),
        opts: safe_pool_opts(metadata[:opts])
      }
    )
  end

  defp log_connection_error(metadata, config) do
    max_chars = Keyword.fetch!(config, :query_log_max_chars)
    error_message = format_error(metadata[:error], max_chars)
    safe_opts = safe_pool_opts(metadata[:opts])

    Logger.warning(
      "DB connection timeout/check-out failure while checking out from pool: " <>
        "error=#{inspect(error_message)} opts=#{inspect(safe_opts)}",
      repo: inspect(Alethea.Repo),
      db_error: error_message,
      db_pool_opts: inspect(safe_opts)
    )
  end

  defp slow_query_message(total_ms, measurements, metadata, config) do
    query = format_query(metadata[:query], Keyword.fetch!(config, :query_log_max_chars))

    "slow database query: total_time=#{format_ms(total_ms)}ms " <>
      "query_time=#{measurement_ms(measurements, :query_time)}ms " <>
      "queue_time=#{measurement_ms(measurements, :queue_time)}ms " <>
      "decode_time=#{measurement_ms(measurements, :decode_time)}ms " <>
      "repo=#{inspect(metadata[:repo])} source=#{inspect(metadata[:source])} " <>
      "query=#{inspect(query)}"
  end

  defp pool_queue_delay_message(queue_ms, threshold_ms, metadata) do
    "database pool queue delay: queue_time=#{format_ms(queue_ms)}ms " <>
      "threshold=#{threshold_ms}ms repo=#{inspect(metadata[:repo])} " <>
      "source=#{inspect(metadata[:source])}"
  end

  defp query_metadata(total_ms, measurements, metadata) do
    repo_metadata(metadata,
      total_time_ms: total_ms,
      query_time_ms: measurement_float_ms(measurements, :query_time),
      queue_time_ms: measurement_float_ms(measurements, :queue_time),
      decode_time_ms: measurement_float_ms(measurements, :decode_time)
    )
  end

  defp repo_metadata(metadata, extra_metadata) do
    [repo: inspect(metadata[:repo]), source: inspect(metadata[:source])] ++ extra_metadata
  end

  defp total_time(measurements) do
    Map.get_lazy(measurements, :total_time, fn ->
      Enum.reduce([:queue_time, :query_time, :decode_time], 0, fn key, acc ->
        acc + Map.get(measurements, key, 0)
      end)
    end)
  end

  defp measurement_ms(measurements, key) do
    measurements
    |> measurement_float_ms(key)
    |> format_ms()
  end

  defp measurement_float_ms(measurements, key) do
    measurements
    |> Map.get(key, 0)
    |> native_to_ms()
  end

  defp native_to_ms(nil), do: 0.0

  defp native_to_ms(time) when is_integer(time) do
    System.convert_time_unit(time, :native, :microsecond) / 1_000
  end

  defp native_to_ms(time) when is_float(time), do: time

  defp format_ms(ms) do
    :erlang.float_to_binary(ms / 1, decimals: 1)
  end

  defp format_query(nil, _max_chars), do: ""

  defp format_query(query, max_chars) when is_binary(query) do
    truncate_text(query, max_chars)
  end

  defp format_query(query, max_chars) do
    query
    |> inspect()
    |> truncate_text(max_chars)
  end

  defp format_error(%{__struct__: _} = error, max_chars) do
    error
    |> Exception.message()
    |> truncate_text(max_chars)
  end

  defp format_error(error, max_chars) do
    error
    |> inspect()
    |> truncate_text(max_chars)
  end

  defp truncate_text(text, max_chars) when max_chars <= 0, do: text

  defp truncate_text(text, max_chars) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "...(truncated)"
    else
      text
    end
  end

  defp safe_pool_opts(nil), do: []

  defp safe_pool_opts(opts) when is_list(opts) do
    Keyword.take(opts, @safe_pool_opts)
  end

  defp safe_pool_opts(_opts), do: []
end
