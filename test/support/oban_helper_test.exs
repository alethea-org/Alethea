defmodule Alethea.Test.ObanHelperTest do
  use Alethea.DataCase, async: false

  import Alethea.Test.ObanHelper

  describe "drain_all_jobs/0" do
    test "drains all queues without error" do
      drain_all_jobs()
      assert true
    end
  end

  describe "drain_queue/1" do
    test "drains specific queue without error" do
      drain_queue(queue: :default)
      assert true
    end

    test "accepts different queue names" do
      drain_queue(queue: :whatsapp)
      drain_queue(queue: :ai_analysis)
      assert true
    end
  end

  describe "find_jobs/1" do
    test "returns empty list when no jobs match" do
      jobs = find_jobs(args: %{non_existent_key: true})
      assert jobs == []
    end

    test "accepts worker filter option" do
      jobs = find_jobs(worker: "AletheaJobs.DailySchedulerWorker", args: %{})
      assert is_list(jobs)
    end

    test "accepts state filter option" do
      jobs = find_jobs(state: "completed")
      assert is_list(jobs)
    end
  end

  describe "count_jobs/1" do
    test "returns zero when no jobs match" do
      count = count_jobs(args: %{non_existent: true})
      assert count == 0
    end

    test "returns non-negative integer" do
      count = count_jobs()
      assert is_integer(count)
      assert count >= 0
    end
  end

  describe "assert_job_count/3" do
    test "passes when zero jobs match" do
      assert assert_job_count(%{non_existent_key: true}, 0) == :ok
    end

    test "fails when count does not match" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_job_count(%{non_existent_fail: true}, 99)
      end
    end
  end
end