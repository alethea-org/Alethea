defmodule AletheaJobs.RetentionSweepWorker do
  @moduledoc """
  Automatic retention sweep (BR4-A, sdd/clinical-record-retention,
  GitHub #197, Phase 3/Slice C). Cron-triggered
  (`{"30 3 * * *", AletheaJobs.RetentionSweepWorker}`,
  `config/config.exs`), queue `clinical_record_retention` with
  concurrency **1** — serializes destructive work and is what makes
  `Alethea.ClinicalRecord.Retention`'s terminal zero-remaining
  crypto-erasure check race-safe (AD4).

  Ships **inert** by two independent guards, checked together on every
  run:

    1. `Application.get_env(:alethea, :retention_sweep_enabled, false)` —
       defaults to `false`; nothing runs at all until explicitly flipped.
    2. `Map.get(args, "dry_run", true)` — even once enabled, a job with
       no `dry_run` arg (the cron-scheduled shape) defaults to dry-run:
       it reports eligible counts per table and writes nothing.

  `max_attempts: 1` — a retry of a partially-completed destructive sweep
  has no value; the next nightly run picks up whatever remains.
  """
  use Oban.Worker, queue: :clinical_record_retention, max_attempts: 1

  require Logger

  alias Alethea.ClinicalRecord.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cond do
      not Application.get_env(:alethea, :retention_sweep_enabled, false) ->
        log_and_ok(:disabled)

      Map.get(args, "dry_run", true) ->
        report_eligible_counts()

      true ->
        sweep()
    end
  end

  defp log_and_ok(reason) do
    Logger.info("RetentionSweepWorker: #{reason}, no-op")
    :ok
  end

  defp report_eligible_counts do
    counts =
      Retention.eligible_records_all_tables()
      |> Enum.group_by(& &1.resource_type)
      |> Map.new(fn {resource_type, records} -> {resource_type, length(records)} end)

    Logger.info("RetentionSweepWorker: dry-run eligible counts=#{inspect(counts)}")
    :ok
  end

  defp sweep do
    Retention.eligible_records_all_tables()
    |> Enum.each(fn %{resource_type: resource_type, resource_id: resource_id} ->
      case Retention.legally_delete_record({resource_type, resource_id},
             actor: :system,
             trigger: "sweep"
           ) do
        {:ok, _tombstone} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "RetentionSweepWorker: skipped #{resource_type}/#{resource_id}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
