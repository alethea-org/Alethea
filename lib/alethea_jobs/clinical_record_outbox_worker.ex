defmodule AletheaJobs.ClinicalRecordOutboxWorker do
  @moduledoc """
  Consumer of `Alethea.ClinicalRecord.Outbox` events
  (sdd/clinical-record-foundation, GitHub #194).

  `perform/1` is intentionally a no-op — this worker exists only to
  drain the `clinical_record_outbox` queue until #196 lands its own
  projection consumer. It pattern-matches the exact identifier-only
  shape built by `Alethea.ClinicalRecord.Outbox.event/2`.
  """
  use Oban.Worker, queue: :clinical_record_outbox, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "event" => _event,
          "resource_type" => _resource_type,
          "resource_id" => _resource_id,
          "patient_id" => _patient_id,
          "professional_id" => _professional_id
        }
      }) do
    :ok
  end
end
