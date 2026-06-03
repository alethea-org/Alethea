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
  end

  describe "check_error_rate/0" do
    test "returns :ok" do
      assert Alethea.ObanTelemetry.check_error_rate() == :ok
    end
  end
end