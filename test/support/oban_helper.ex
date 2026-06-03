defmodule Alethea.Test.ObanHelper do
  @moduledoc """
  Test utilities for Oban workers.

  Provides helpers for running and asserting on Oban jobs in tests.

  ## Usage

      use ExUnit.Case
      import Alethea.Test.ObanHelper

      test "my worker" do
        # Inline execution (preferred for unit tests)
        :ok = run_job(MyWorker, %{"arg" => "value"})

        # Assert job was enqueued with specific args
        assert_job_enqueued(MyWorker, %{"patient_id" => 123})

        # Wait for job completion with timeout
        :ok = wait_for_job_completion(MyWorker, %{"id" => 1}, 5_000)
      end

  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  @default_timeout 5_000

  @doc """
  Executes a job inline without going through Oban's queue.

  This is the preferred method for unit testing workers as it:
  - Runs synchronously (no async issues)
  - Returns the result directly
  - Does not require Oban to be running

  ## Examples

      run_job(MyWorker, %{"arg" => "value"})
      # => :ok or {:ok, result}

  """
  @spec run_job(module(), map()) :: :ok | {:ok, any()} | {:error, any()}
  def run_job(worker, args) when is_map(args) do
    %Oban.Job{args: args}
    |> worker.perform()
  end

  @doc """
  Executes a job inline with the given opts.

  Supports additional Oban.Job fields like `:schedule_at`, `:max_attempts`, etc.
  """
  @spec run_job(module(), map(), keyword()) :: :ok | {:ok, any()} | {:error, any()}
  def run_job(worker, args, opts) when is_map(args) and is_list(opts) do
    job_opts = Keyword.take(opts, [:schedule_at, :max_attempts, :priority, :tags])

    %Oban.Job{args: args}
    |> Map.merge(Map.new(job_opts))
    |> worker.perform()
  end

  @doc """
  Asserts that a job was enqueued with matching args.

  Uses Oban's built-in assertion helpers.

  ## Examples

      assert_job_enqueued(MyWorker, %{"patient_id" => 123})

  """
  @spec assert_job_enqueued(worker :: module(), args :: map()) :: term()
  def assert_job_enqueued(worker, args) when is_map(args) do
    Oban.Testing.assert_enqueued(
      Oban,
      worker: worker,
      args: args
    )
  end

  @doc """
  Asserts that a job was enqueued within a time window.

  Useful for jobs scheduled in the future.

  ## Examples

      assert_job_enqueued(MyWorker, %{"id" => 1}, scheduled_at: 60_000)

  """
  @spec assert_job_enqueued(worker :: module(), args :: map(), opts :: keyword()) :: term()
  def assert_job_enqueued(worker, args, opts) when is_map(args) and is_list(opts) do
    Oban.Testing.assert_enqueued(
      Oban,
      Keyword.merge([worker: worker, args: args], opts)
    )
  end

  @doc """
  Refutes that a job was enqueued with matching args.
  """
  @spec refute_job_enqueued(worker :: module(), args :: map()) :: term()
  def refute_job_enqueued(worker, args) when is_map(args) do
    Oban.Testing.refute_enqueued(
      Oban,
      worker: worker,
      args: args
    )
  end

  @doc """
  Waits for a job to complete by polling the Oban jobs table.

  Returns `:ok` when the job completes successfully, or `{:error, reason}`
  if it fails or times out.

  ## Options

    * `:timeout` - Maximum time to wait in ms (default: #{@default_timeout})
    * `:poll_interval` - Time between checks in ms (default: 100)

  ## Examples

      wait_for_job_completion(MyWorker, %{"id" => 1})
      wait_for_job_completion(MyWorker, %{"id" => 1}, timeout: 10_000)

  """
  @spec wait_for_job_completion(worker :: module(), args :: map(), timeout :: pos_integer()) ::
          :ok | {:error, :timeout}
  def wait_for_job_completion(worker, args, timeout \\ @default_timeout)

  def wait_for_job_completion(worker, args, timeout) when is_map(args) and is_integer(timeout) do
    wait_for_job_completion(worker, args, timeout: timeout)
  end

  def wait_for_job_completion(worker, args, opts) when is_map(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, 100)

    worker_name = worker |> Module.split() |> List.last() |> Macro.underscore()

    deadline = System.system_time(:millisecond) + timeout

    do_wait_for_job(worker_name, args, poll_interval, deadline)
  end

  defp do_wait_for_job(worker_name, args, poll_interval, deadline) do
    if System.system_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      do_wait_for_job_poll(worker_name, args, poll_interval, deadline)
    end
  end

  defp do_wait_for_job_poll(worker_name, args, poll_interval, deadline) do
    case find_completed_job(worker_name, args) do
      {:ok, _job} ->
        :ok

      :not_found ->
        Process.sleep(poll_interval)
        do_wait_for_job(worker_name, args, poll_interval, deadline)
    end
  end

  defp find_completed_job(worker_name, args) do
    encoded_args = Jason.encode!(args)

    query =
      from(j in fragment("oban_jobs"),
        where: fragment("worker = ?", ^worker_name),
        where: fragment("state = 'completed'"),
        where: fragment("args = ?::jsonb", ^encoded_args),
        order_by: [desc: fragment("id")],
        limit: 1
      )

    case Alethea.Repo.one(query) do
      nil -> :not_found
      _job -> {:ok, %{state: "completed"}}
    end
  rescue
    _ -> :not_found
  end

  @doc """
  Asserts that a job completed successfully within the timeout.

  Shortcut for `wait_for_job_completion/3` with assertion.

  ## Examples

      assert_job_completed(MyWorker, %{"id" => 1})

  """
  @spec assert_job_completed(worker :: module(), args :: map(), timeout :: pos_integer()) ::
          :ok | no_return()
  def assert_job_completed(worker, args, timeout \\ @default_timeout) do
    case wait_for_job_completion(worker, args, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk("Job #{inspect(worker)} with args #{inspect(args)} did not complete within #{timeout}ms")

      {:error, reason} ->
        flunk("Job #{inspect(worker)} failed: #{inspect(reason)}")
    end
  end
end