defmodule Alethea.ObanTelemetryTest do
  use ExUnit.Case, async: false

  describe "alert_config/0" do
    test "returns error rate and slow job thresholds" do
      config = Alethea.ObanTelemetry.alert_config()

      assert config[:error_rate_threshold] == 0.05
      assert config[:slow_job_threshold_ms] == 5_000
      assert :log in config[:alert_channels]
      assert :metrics in config[:alert_channels]
    end
  end

  describe "metrics/0" do
    test "returns list of Oban-related metrics" do
      metrics = Alethea.ObanTelemetry.metrics()

      assert is_list(metrics)
      assert length(metrics) > 0

      # Verify metric names are present (they are lists, not atoms)
      metric_names = Enum.map(metrics, & &1.name)
      assert [:alethea, :oban, :job, :stop, :count] in metric_names
      assert [:alethea, :oban, :job, :exception, :count] in metric_names
    end

    test "keeps emitted millisecond durations unchanged" do
      duration_metrics =
        Alethea.ObanTelemetry.metrics()
        |> Enum.filter(
          &(&1.name in [
              [:alethea, :oban, :job, :stop, :duration_ms],
              [:alethea, :oban, :job, :exception, :duration_ms]
            ])
        )

      assert length(duration_metrics) == 2

      for metric <- duration_metrics do
        assert metric.unit == :millisecond
        assert metric.measurement == :duration_ms
      end
    end
  end

  describe "handle_stop/4" do
    setup do
      handler_id = "oban-telemetry-test-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:alethea, :oban, :job, :stop],
          fn event, measurements, metadata, test_pid ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "emits successful Oban 2.22 stop metadata with measured duration and no job content" do
      duration = System.convert_time_unit(42, :millisecond, :native)

      metadata = %{
        state: :success,
        result: :ok,
        worker: "AletheaJobs.AIProposalWorker",
        queue: "ai",
        id: 123,
        attempt: 2,
        args: %{"clinical_note" => "private clinical content"},
        job: %{args: %{"clinical_note" => "private clinical content"}}
      }

      Alethea.ObanTelemetry.handle_stop(
        [:oban, :job, :stop],
        %{duration: duration},
        metadata,
        nil
      )

      assert_receive {:telemetry_event, [:alethea, :oban, :job, :stop], measurements,
                      emitted_metadata}

      assert measurements == %{duration_ms: 42}

      assert emitted_metadata == %{
               worker: "AletheaJobs.AIProposalWorker",
               queue: "ai",
               job_id: 123,
               attempt: 2,
               success: true
             }
    end

    test "marks a non-successful Oban stop state as unsuccessful" do
      duration = System.convert_time_unit(7, :millisecond, :native)

      metadata = %{
        state: :cancelled,
        result: {:cancel, :requested},
        worker: "AletheaJobs.AIProposalWorker",
        queue: "ai",
        id: 456,
        attempt: 1
      }

      Alethea.ObanTelemetry.handle_stop(
        [:oban, :job, :stop],
        %{duration: duration},
        metadata,
        nil
      )

      assert_receive {:telemetry_event, [:alethea, :oban, :job, :stop], measurements,
                      emitted_metadata}

      assert measurements == %{duration_ms: 7}

      assert emitted_metadata == %{
               worker: "AletheaJobs.AIProposalWorker",
               queue: "ai",
               job_id: 456,
               attempt: 1,
               success: false
             }
    end

    test "the application-attached handler translates Oban stop events" do
      duration = System.convert_time_unit(11, :millisecond, :native)

      :telemetry.execute(
        [:oban, :job, :stop],
        %{duration: duration},
        %{
          state: :success,
          result: :ok,
          worker: "AletheaJobs.AIProposalWorker",
          queue: "ai",
          id: 789,
          attempt: 1,
          args: %{"clinical_note" => "private clinical content"}
        }
      )

      assert_receive {:telemetry_event, [:alethea, :oban, :job, :stop], measurements,
                      emitted_metadata}

      assert measurements == %{duration_ms: 11}

      assert emitted_metadata == %{
               worker: "AletheaJobs.AIProposalWorker",
               queue: "ai",
               job_id: 789,
               attempt: 1,
               success: true
             }
    end
  end

  describe "check_error_rate/0" do
    test "returns :ok" do
      assert Alethea.ObanTelemetry.check_error_rate() == :ok
    end
  end
end
