defmodule AletheaJobs.SessionRecordingCleanupWorkerTest do
  @moduledoc """
  `AletheaJobs.SessionRecordingCleanupWorker` (session-recording S7): abandoned
  recordings are finalized and transcriptions stuck without a job fail and
  lose their audio, so nothing stays forever with encrypted audio.
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{Audit, SessionRecording, SessionRecordingChunk}
  alias Alethea.TranscriptionStub
  alias AletheaJobs.{SessionRecordingCleanupWorker, SessionTranscriptionWorker}

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  defp start!(professional, patient, chunks) do
    {:ok, recording} =
      ClinicalRecord.start_session_recording(professional, patient.id, %{
        consent: true,
        content_type: "audio/webm"
      })

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {data, seq} ->
      :ok =
        ClinicalRecord.append_session_recording_chunk(
          professional,
          patient.id,
          recording.id,
          seq,
          data
        )
    end)

    recording
  end

  # Runs the cron job as if `minutes` had passed since now.
  defp run_after(minutes) do
    now = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
    perform_job(SessionRecordingCleanupWorker, %{"now" => DateTime.to_iso8601(now)})
  end

  defp chunk_count(recording_id) do
    Repo.aggregate(
      from(c in SessionRecordingChunk, where: c.session_recording_id == ^recording_id),
      :count
    )
  end

  defp failed_audits(recording_id) do
    Repo.all(
      from a in Audit,
        where: a.action == "session_recording_failed" and a.resource_id == ^recording_id
    )
  end

  test "runs from cron every ten minutes on the transcription queue" do
    assert SessionRecordingCleanupWorker.__opts__()[:queue] == :transcription
    assert SessionRecordingCleanupWorker.abandoned_after_seconds() == 15 * 60
    assert SessionRecordingCleanupWorker.stalled_after_seconds() == 30 * 60

    crontab =
      :alethea
      |> Application.get_env(Oban)
      |> Keyword.fetch!(:plugins)
      |> Keyword.fetch!(Oban.Plugins.Cron)
      |> Keyword.fetch!(:crontab)

    assert {"*/10 * * * *", SessionRecordingCleanupWorker} in crontab
  end

  test "an abandoned recording with chunks moves on to transcription", %{
    professional: professional,
    patient: patient
  } do
    recording = start!(professional, patient, ["AAA", "BBB"])

    assert :ok = run_after(16)

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "transcribing"
    assert chunk_count(recording.id) == 2

    assert_enqueued(
      worker: SessionTranscriptionWorker,
      args: %{"session_recording_id" => recording.id}
    )
  end

  test "an abandoned recording without chunks fails as empty_recording", %{
    professional: professional,
    patient: patient
  } do
    recording = start!(professional, patient, [])

    assert :ok = run_after(16)

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "failed"
    assert stored.error_code == "empty_recording"
    assert [_] = failed_audits(recording.id)
    refute_enqueued(worker: SessionTranscriptionWorker)
  end

  test "a recording that received a chunk recently is left alone", %{
    professional: professional,
    patient: patient
  } do
    recording = start!(professional, patient, ["AAA"])

    # Started long ago, but its newest chunk is only 5 minutes old.
    Repo.update_all(
      from(r in SessionRecording, where: r.id == ^recording.id),
      set: [recorded_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
    )

    assert :ok = run_after(5)
    assert :ok = run_after(14)

    assert Repo.get!(SessionRecording, recording.id).status == "recording"
    assert chunk_count(recording.id) == 1
    refute_enqueued(worker: SessionTranscriptionWorker)
  end

  test "a stalled transcription without a job fails and loses its audio", %{
    professional: professional,
    patient: patient
  } do
    recording = start!(professional, patient, ["AAA"])

    {:ok, _} = ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)
    # The job died (crash or timeout on its last attempt).
    Repo.delete_all(Oban.Job)

    assert :ok = run_after(29)
    assert Repo.get!(SessionRecording, recording.id).status == "transcribing"

    assert :ok = run_after(31)

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "failed"
    assert stored.error_code == "stalled"
    assert chunk_count(recording.id) == 0
    assert [_] = failed_audits(recording.id)
  end

  test "a transcription with a live job is left alone", %{
    professional: professional,
    patient: patient
  } do
    recording = start!(professional, patient, ["AAA"])
    {:ok, _} = ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)

    for state <- ~w(available scheduled executing retryable) do
      Repo.update_all(Oban.Job, set: [state: state])
      assert :ok = run_after(60)
      assert Repo.get!(SessionRecording, recording.id).status == "transcribing"
    end

    assert chunk_count(recording.id) == 1
    assert failed_audits(recording.id) == []
  end

  test "settled recordings are not touched", %{professional: professional, patient: patient} do
    TranscriptionStub.install(%{
      text: "Una voz.",
      language: "es",
      duration: 1.0,
      segments: [%{start: 0.0, end: 1.0, text: "Una voz.", speaker: nil}]
    })

    ready = start!(professional, patient, ["AAA"])
    {:ok, _} = ClinicalRecord.finish_session_recording(professional, patient.id, ready.id)
    :ok = perform_job(SessionTranscriptionWorker, %{"session_recording_id" => ready.id})

    assert :ok = run_after(120)

    stored = Repo.get!(SessionRecording, ready.id)
    assert stored.status == "ready"
    assert failed_audits(ready.id) == []
  end
end
