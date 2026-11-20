defmodule AletheaJobs.SessionTranscriptionWorker do
  @moduledoc """
  Transcribes one `Alethea.ClinicalRecord.SessionRecording` through the
  configured `Alethea.AI.Whisper` adapter (session-recording S2/S3).

  Transcription never runs in the request: `ClinicalRecord.create_session_recording/3`
  enqueues this job in the same transaction as the recording row. The job is
  unique per recording while pending or running.

  Up to three attempts: a provider error before the last attempt returns
  `{:error, code}` so Oban retries with the audio still stored; on the last
  attempt the recording is marked `"failed"` and its audio deleted. Audio and
  transcript text are never logged — only the error code.
  """
  use Oban.Worker,
    queue: :transcription,
    max_attempts: 3,
    unique: [
      keys: [:session_recording_id],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Alethea.ClinicalRecord

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"session_recording_id" => recording_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case ClinicalRecord.process_session_recording(recording_id,
           final_attempt?: attempt >= max_attempts
         ) do
      {:ok, _recording_or_skipped} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Large audio can take minutes to transcribe; the adapter has its own
  # receive timeout, this bounds the whole job.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)
end
