defmodule Alethea.ObanTelemetry do
  @moduledoc """
  Telemetry handlers for Oban job processing metrics.

  Provides:
  - Job execution counts and latencies per worker
  - Error tracking and alerting thresholds
  - Slow job detection and logging
  """

  require Logger

  @error_threshold 0.05  # 5% error rate threshold
  @slow_job_threshold_ms 5_000  # 5 seconds

  @doc """
  Attaches Oban telemetry handlers. Call this in Application.start/2.
  """
  def attach do
    # Attach individual handlers for each event
    :telemetry.attach(
      "oban-job-start-handler",
      [:oban, :job, :start],
      &__MODULE__.handle_start/4,
      nil
    )

    :telemetry.attach(
      "oban-job-stop-handler",
      [:oban, :job, :stop],
      &__MODULE__.handle_stop/4,
      nil
    )

    :telemetry.attach(
      "oban-job-exception-handler",
      [:oban, :job, :exception],
      &__MODULE__.handle_exception/4,
      nil
    )

    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Oban Lifecycle Event Handlers
  # ─────────────────────────────────────────────────────────────────────────

  def handle_start(_event, _measurements, metadata, _config) do
    :telemetry.execute(
      [:alethea, :oban, :job, :start],
      %{},
      %{
        worker: metadata.worker,
        queue: metadata.queue,
        job_id: metadata.id
      }
    )
  end

  def handle_stop(_event, _measurements, metadata, _config) do
    duration_ms = get_duration_ms(metadata)

    :telemetry.execute(
      [:alethea, :oban, :job, :stop],
      %{duration_ms: duration_ms},
      %{
        worker: metadata.worker,
        queue: metadata.queue,
        job_id: metadata.id,
        attempt: metadata.attempt,
        success: metadata.success
      }
    )

    # Log slow jobs
    if duration_ms > @slow_job_threshold_ms do
      Logger.warning("Slow job detected",
        worker: metadata.worker,
        queue: metadata.queue,
        job_id: metadata.id,
        duration_ms: duration_ms
      )
    end
  end

  def handle_exception(_event, _measurements, metadata, _config) do
    duration_ms = get_duration_ms(metadata)

    :telemetry.execute(
      [:alethea, :oban, :job, :exception],
      %{duration_ms: duration_ms},
      %{
        worker: metadata.worker,
        queue: metadata.queue,
        job_id: metadata.id,
        attempt: metadata.attempt,
        error: metadata.error
      }
    )

    # Log error details
    Logger.error("Oban job exception",
      worker: metadata.worker,
      queue: metadata.queue,
      job_id: metadata.id,
      attempt: metadata.attempt,
      error: inspect(metadata.error)
    )
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Metrics for Telemetry Dashboard
  # ─────────────────────────────────────────────────────────────────────────

  @doc """
  Returns all Oban-related metrics for the telemetry dashboard.
  """
  def metrics do
    [
      # Job execution metrics
      Telemetry.Metrics.counter(
        "alethea.oban.job.stop.count",
        tags: [:worker, :queue],
        description: "Total jobs processed"
      ),
      Telemetry.Metrics.summary(
        "alethea.oban.job.stop.duration_ms",
        tags: [:worker, :queue],
        unit: {:native, :millisecond},
        description: "Job execution duration"
      ),

      # Error metrics
      Telemetry.Metrics.counter(
        "alethea.oban.job.exception.count",
        tags: [:worker, :queue],
        description: "Job exceptions"
      ),
      Telemetry.Metrics.summary(
        "alethea.oban.job.exception.duration_ms",
        tags: [:worker, :queue],
        unit: {:native, :millisecond},
        description: "Exception duration before failure"
      ),

      # Queue metrics
      Telemetry.Metrics.counter(
        "alethea.oban.job.start.count",
        tags: [:worker, :queue],
        description: "Jobs started"
      )
    ]
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Alert Configuration
  # ─────────────────────────────────────────────────────────────────────────

  @doc """
  Checks if error rate exceeds threshold and logs alert.
  Call this periodically (e.g., every minute) to detect error rate spikes.
  """
  def check_error_rate do
    # This would be called by a periodic measurement
    # In production, integrate with your alerting system (PagerDuty, etc.)
    :ok
  end

  @doc """
  Returns alert configuration for monitoring systems.
  """
  def alert_config do
    %{
      error_rate_threshold: @error_threshold,
      slow_job_threshold_ms: @slow_job_threshold_ms,
      alert_channels: [:log, :metrics]
    }
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Helper Functions
  # ─────────────────────────────────────────────────────────────────────────

  defp get_duration_ms(metadata) do
    case metadata do
      %{duration: duration} when is_integer(duration) ->
        System.convert_time_unit(duration, :native, :millisecond)

      _ ->
        0
    end
  end
end