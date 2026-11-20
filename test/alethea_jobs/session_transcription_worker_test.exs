defmodule AletheaJobs.SessionTranscriptionWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{Audit, SessionRecording, SessionTranscript}
  alias Alethea.TranscriptionStub
  alias AletheaJobs.{ClinicalRecordOutboxWorker, SessionTranscriptionWorker}

  @audio "fake-ogg-audio-bytes"

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)

    {:ok, recording} =
      ClinicalRecord.create_session_recording(professional, patient.id, %{
        audio: @audio,
        content_type: "audio/ogg",
        consent: true
      })

    %{professional: professional, patient: patient, recording: recording}
  end

  defp run(recording, attempt \\ 1) do
    perform_job(SessionTranscriptionWorker, %{"session_recording_id" => recording.id},
      attempt: attempt
    )
  end

  defp audit_actions(recording_id) do
    Repo.all(
      from a in Audit,
        where: a.resource_id == ^recording_id,
        order_by: a.inserted_at,
        select: a.action
    )
  end

  test "is configured for the transcription queue with three attempts" do
    job = SessionTranscriptionWorker.new(%{"session_recording_id" => Ecto.UUID.generate()})
    assert job.changes.queue == "transcription"
    assert job.changes.max_attempts == 3
  end

  test "a diarized result waits for speakers and deletes the audio", %{recording: recording} do
    TranscriptionStub.install(%{
      text: "Hola. Hola.",
      language: "es",
      duration: 10.0,
      segments: [
        %{start: 0.0, end: 4.0, text: "Hola.", speaker: 0},
        %{start: 4.0, end: 10.0, text: "Hola.", speaker: 1}
      ]
    })

    assert :ok = run(recording)

    assert_received {:transcription_stub_called, @audio, opts}
    assert opts[:content_type] == "audio/ogg"
    assert opts[:language] == "es"

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "needs_speakers"
    assert stored.encrypted_audio == nil
    assert is_binary(stored.encrypted_segments)
    assert stored.audio_duration_seconds == 10
    assert stored.session_transcript_id == nil
    assert Repo.aggregate(SessionTranscript, :count) == 0
    assert "session_recording_transcribed" in audit_actions(recording.id)
  end

  for {label, segments} <- [
        {"a single speaker", [%{start: 0.0, end: 3.0, text: "Una sola voz.", speaker: 0}]},
        {"no speakers", [%{start: 0.0, end: 3.0, text: "Una sola voz.", speaker: nil}]}
      ] do
    test "#{label} becomes a ready transcript with unknown spans", %{
      professional: professional,
      patient: patient,
      recording: recording
    } do
      TranscriptionStub.install(%{
        text: "Una sola voz.",
        language: "es",
        duration: 3.0,
        segments: unquote(Macro.escape(segments))
      })

      assert :ok = run(recording)

      stored = Repo.get!(SessionRecording, recording.id)
      assert stored.status == "ready"
      assert stored.encrypted_audio == nil
      assert is_binary(stored.session_transcript_id)

      assert {:ok, %SessionTranscript{spans: spans, audio_duration_seconds: 3}} =
               ClinicalRecord.get_session_transcript(
                 professional,
                 patient.id,
                 stored.session_transcript_id
               )

      assert spans == [%{start: 0.0, end: 3.0, speaker: "unknown", text: "Una sola voz."}]

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{
          "event" => "session_transcript_created",
          "resource_id" => stored.session_transcript_id
        }
      )

      assert "session_recording_transcribed" in audit_actions(recording.id)
    end
  end

  test "a provider error before the last attempt keeps the audio for a retry", %{
    recording: recording
  } do
    TranscriptionStub.install({:error, :timeout})

    assert {:error, "provider_timeout"} = run(recording, 2)

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "transcribing"
    assert is_binary(stored.encrypted_audio)
    assert stored.error_code == nil
  end

  test "a provider error on the last attempt fails the recording and deletes the audio", %{
    recording: recording
  } do
    TranscriptionStub.install({:error, {:http_error, 500, "secret transcript text"}})

    assert :ok = run(recording, 3)

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "failed"
    assert stored.encrypted_audio == nil
    assert stored.error_code == "provider_error"
    assert "session_recording_failed" in audit_actions(recording.id)
  end

  test "an empty transcription fails without retrying", %{recording: recording} do
    TranscriptionStub.install(%{text: "", language: "es", duration: 2.0, segments: []})

    assert :ok = run(recording)

    stored = Repo.get!(SessionRecording, recording.id)
    assert stored.status == "failed"
    assert stored.error_code == "empty_transcript"
    assert stored.encrypted_audio == nil
  end

  test "a recording no longer transcribing is skipped", %{recording: recording} do
    TranscriptionStub.install({:error, :timeout})

    recording
    |> SessionRecording.transition_changeset(%{status: "failed", encrypted_audio: nil})
    |> Repo.update!()

    assert :ok = run(recording)
    refute_received {:transcription_stub_called, _audio, _opts}
  end
end
