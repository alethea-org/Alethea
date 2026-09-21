defmodule AletheaJobs.ClinicalRecordOutboxWorker do
  @moduledoc """
  Consumer of `Alethea.ClinicalRecord.Outbox` events
  (sdd/clinical-record-foundation, GitHub #194).

  As of sdd/telegram-rag-ingestion-262 (GitHub #262, Slice 1) it also
  consumes `Alethea.Clinical.Outbox` events (`patient_message_received`,
  the "voz del paciente" producer) on the SAME queue — the name is kept
  unchanged (Q4) because Oban persists it verbatim in
  `oban_jobs.worker`; renaming would break in-flight/retryable jobs and
  the job history's `worker` column. Both producers build the identical
  5-key args shape, so this worker's `perform/1` pattern match and
  `Indexer.index_event/1` dispatch are unchanged and generic over the
  event source.

  Dispatches every eligible event to
  `Alethea.ClinicalRecord.Rag.Indexer.index_event/1`
  (sdd/clinical-rag-projection, GitHub #196, WU3, design section 4)
  and classifies the result for Oban:

  - `:ok` (indexed, or a recognized-ignore/unknown tombstone-seam
    event) → `:ok`, the job completes.
  - `{:cancel, _}` from the indexer (embedding dimension mismatch) or
    a missing source row (`{:error, :not_found}`, remapped here to
    `{:cancel, :not_found}`) → permanent failure, no further
    retries. A retry cannot fix a deleted resource or a config
    mismatch.
  - Any other `{:error, _}` (embedding provider/HTTP/DB transient
    failure) → `{:error, _}`, so Oban retries with exponential
    backoff up to `max_attempts`.
  - Malformed args (missing an identifier key) → `{:cancel,
    {:malformed_args, keys}}` instead of raising
    `FunctionClauseError` — the pre-#196 worker crashed on this
    shape; crashing repeatedly on unfixable input is wrong.
  """
  use Oban.Worker, queue: :clinical_record_outbox, max_attempts: 5

  alias Alethea.ClinicalRecord.Rag.Indexer

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "event" => _event,
            "resource_type" => _resource_type,
            "resource_id" => _resource_id,
            "patient_id" => _patient_id,
            "professional_id" => _professional_id
          } = args
      }) do
    args
    |> Indexer.index_event()
    |> classify()
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:malformed_args, Map.keys(args)}}
  end

  defp classify(:ok), do: :ok
  defp classify({:cancel, _reason} = cancel), do: cancel
  defp classify({:error, :not_found}), do: {:cancel, :not_found}
  defp classify({:error, _reason} = error), do: error
end
