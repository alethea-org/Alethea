defmodule AletheaJobs.SessionRecordingCleanupWorker do
  @moduledoc """
  Periodic cleanup of session recordings (session-recording S7), run by
  `Oban.Plugins.Cron` every 10 minutes. Nothing stays forever with encrypted
  audio:

    * a recording still `"recording"` with no chunk for
      15 minutes (the tab was closed or the connection lost)
      is finished: transcribed if it has chunks, failed `"empty_recording"`
      otherwise;
    * a recording `"transcribing"` for 30 minutes without a live
      `AletheaJobs.SessionTranscriptionWorker` job (it crashed or timed out on
      its last attempt) is failed `"stalled"` and its chunks deleted.

  The work lives in `Alethea.ClinicalRecord.clean_up_session_recordings/3`.
  Job args may carry `"now"` (ISO 8601) so tests can move the clock.
  """
  use Oban.Worker,
    queue: :transcription,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  alias Alethea.ClinicalRecord

  @abandoned_after_seconds 15 * 60
  @stalled_after_seconds 30 * 60

  @doc "Seconds without a chunk after which a recording counts as abandoned."
  def abandoned_after_seconds, do: @abandoned_after_seconds

  @doc "Seconds a transcribing recording may go without a job before failing."
  def stalled_after_seconds, do: @stalled_after_seconds

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now =
      with %{"now" => iso} <- args,
           {:ok, now, _offset} <- DateTime.from_iso8601(iso) do
        now
      else
        _ -> DateTime.utc_now()
      end

    ClinicalRecord.clean_up_session_recordings(
      now,
      @abandoned_after_seconds,
      @stalled_after_seconds
    )

    :ok
  end
end
