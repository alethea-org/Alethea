defmodule Alethea.Test.ObanHelper do
  @moduledoc """
  Helper utilities for testing Oban workers reliably.

  Provides functions to drain jobs, wait for completion, and
  assert on worker execution without flaky sleeps.

  ## Usage

      defmodule MyWorkerTest do
        use ExUnit.Case, async: false
        import Alethea.Test.ObanHelper

        test "processes job correctly" do
          MyWorker.new(%{data: "value"})
          |> Oban.insert!()

          drain_all_jobs()
        end
      end

  """

  import Ecto.Query
  alias Oban.Job

  @doc """
  Drains all pending and available jobs across all queues.
  """
  @spec drain_all_jobs() :: :ok
  def drain_all_jobs do
    Oban.drain_queue(queue: :default)
    Oban.drain_queue(queue: :whatsapp)
    Oban.drain_queue(queue: :ai_analysis)
    :ok
  end

  @doc """
  Drains jobs from a specific queue.
  """
  @spec drain_queue(Keyword.t()) :: :ok
  def drain_queue(opts) do
    queue = Keyword.fetch!(opts, :queue)
    Oban.drain_queue(queue: queue)
    :ok
  end

  @doc """
  Retrieves all jobs with matching args.
  """
  @spec find_jobs(opts :: Keyword.t()) :: [Job.t()]
  def find_jobs(opts \\ []) do
    args = Keyword.get(opts, :args, %{})
    state = Keyword.get(opts, :state, nil)
    worker = Keyword.get(opts, :worker, nil)

    Job
    |> maybe_where_worker(worker)
    |> where([j], fragment("args @> ?", ^Jason.encode!(args)))
    |> order_by([j], desc: j.inserted_at)
    |> maybe_where_state(state)
    |> Alethea.Repo.all()
  end

  @doc """
  Counts jobs matching the given criteria.
  """
  @spec count_jobs(opts :: Keyword.t()) :: non_neg_integer()
  def count_jobs(opts \\ []) do
    args = Keyword.get(opts, :args, %{})
    state = Keyword.get(opts, :state, nil)
    worker = Keyword.get(opts, :worker, nil)

    Job
    |> maybe_where_worker(worker)
    |> where([j], fragment("args @> ?", ^Jason.encode!(args)))
    |> maybe_where_state(state)
    |> select([j], count())
    |> Alethea.Repo.one()
  end

  @doc """
  Asserts the exact number of jobs with given criteria.
  """
  @spec assert_job_count(args :: map(), count :: non_neg_integer(), opts :: Keyword.t()) :: :ok
  def assert_job_count(args, expected_count, opts \\ []) do
    state = Keyword.get(opts, :state, "completed")
    worker = Keyword.get(opts, :worker, nil)

    actual_count = count_jobs(args: args, state: state, worker: worker)

    unless actual_count == expected_count do
      ExUnit.Assertions.flunk("""
      Expected #{expected_count} job(s) with args #{inspect(args)}, state #{state}
      but found #{actual_count} job(s)
      """)
    end

    :ok
  end

  # Private helpers

  defp maybe_where_worker(query, nil), do: query

  defp maybe_where_worker(query, worker) when is_binary(worker),
    do: where(query, [j], j.worker == ^worker)

  defp maybe_where_state(query, nil), do: query
  defp maybe_where_state(query, state), do: where(query, [j], j.state == ^state)
end
