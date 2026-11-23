defmodule Alethea.ClinicalRecord.SessionRecordingTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    Audit,
    SessionRecording,
    SessionRecordingChunk,
    SessionRecordings,
    SessionTranscript
  }

  alias Alethea.Encryption.PatientVault
  alias Alethea.TranscriptionStub
  alias AletheaJobs.{ClinicalRecordOutboxWorker, SessionTranscriptionWorker}

  @audio "fake-webm-audio-bytes"

  @diarized %{
    text: "Hola, ¿cómo estás? Mal. Contame más. No dormí.",
    language: "es",
    duration: 42.4,
    segments: [
      %{start: 0.0, end: 2.0, text: "Hola, ¿cómo estás?", speaker: 0},
      %{start: 2.0, end: 3.5, text: "Mal.", speaker: 1},
      %{start: 3.5, end: 5.0, text: "Contame más.", speaker: 0},
      %{start: 5.0, end: 7.0, text: "No dormí.", speaker: 1},
      %{start: 7.0, end: 9.0, text: "Tercera línea.", speaker: 0}
    ]
  }

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  defp start_recording!(professional, patient) do
    {:ok, recording} =
      ClinicalRecord.start_session_recording(professional, patient.id, %{
        consent: true,
        content_type: "audio/webm;codecs=opus"
      })

    recording
  end

  defp append!(professional, patient, recording, seq, data) do
    :ok =
      ClinicalRecord.append_session_recording_chunk(
        professional,
        patient.id,
        recording.id,
        seq,
        data
      )
  end

  # A finished recording with one chunk (`@audio`), waiting for transcription.
  defp create_recording!(professional, patient) do
    recording = start_recording!(professional, patient)
    append!(professional, patient, recording, 0, @audio)

    {:ok, recording} =
      ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)

    recording
  end

  defp chunks(recording_id) do
    Repo.all(
      from c in SessionRecordingChunk,
        where: c.session_recording_id == ^recording_id,
        order_by: c.seq
    )
  end

  defp clinical_record_dek(professional, patient) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.ensure_clinical_record_dek(patient, kek)
    dek
  end

  defp audits(action, recording_id) do
    Repo.all(from a in Audit, where: a.action == ^action and a.resource_id == ^recording_id)
  end

  describe "start_session_recording/3" do
    test "creates a recording in progress and audits it", %{
      professional: professional,
      patient: patient
    } do
      Phoenix.PubSub.subscribe(Alethea.PubSub, SessionRecordings.topic(patient.id))
      recording = start_recording!(professional, patient)

      stored = Repo.get!(SessionRecording, recording.id)
      assert stored.status == "recording"
      assert stored.content_type == "audio/webm;codecs=opus"
      assert stored.patient_id == patient.id
      assert stored.professional_id == professional.id
      assert %DateTime{} = stored.consent_confirmed_at
      assert %DateTime{} = stored.recorded_at

      assert [%Audit{professional_id: prof_id, resource_type: "session_recording"} = audit] =
               audits("session_recording_created", recording.id)

      assert prof_id == professional.id
      assert audit.details == %{"outcome" => "success"}
      refute_enqueued(worker: SessionTranscriptionWorker)
      assert_receive {:session_recording_updated, id} when id == recording.id
    end

    test "accepts audio/mp4 for Safari", %{professional: professional, patient: patient} do
      assert {:ok, %SessionRecording{content_type: "audio/mp4"}} =
               ClinicalRecord.start_session_recording(professional, patient.id, %{
                 consent: true,
                 content_type: "audio/mp4"
               })
    end

    test "requires consent and stores nothing without it", %{
      professional: professional,
      patient: patient
    } do
      assert {:error, :consent_required} =
               ClinicalRecord.start_session_recording(professional, patient.id, %{
                 content_type: "audio/webm"
               })

      assert Repo.aggregate(SessionRecording, :count) == 0

      assert Repo.aggregate(
               from(a in Audit, where: a.action == "session_recording_created"),
               :count
             ) ==
               0
    end

    test "rejects content types other than webm or mp4 audio", %{
      professional: professional,
      patient: patient
    } do
      for type <- ["audio/ogg", "video/webm", "text/plain", "", nil] do
        assert {:error, :invalid_content_type} =
                 ClinicalRecord.start_session_recording(professional, patient.id, %{
                   consent: true,
                   content_type: type
                 })
      end

      assert Repo.aggregate(SessionRecording, :count) == 0
    end

    test "another professional cannot start, append, finish, list, get or assign", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)
      intruder = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.start_session_recording(intruder, patient.id, %{
                 consent: true,
                 content_type: "audio/webm"
               })

      assert {:error, :unauthorized} =
               ClinicalRecord.append_session_recording_chunk(
                 intruder,
                 patient.id,
                 recording.id,
                 0,
                 @audio
               )

      assert {:error, :unauthorized} =
               ClinicalRecord.finish_session_recording(intruder, patient.id, recording.id)

      assert {:error, :unauthorized} =
               ClinicalRecord.list_session_recordings(intruder, patient.id)

      assert {:error, :unauthorized} =
               ClinicalRecord.get_session_recording(intruder, patient.id, recording.id)

      assert {:error, :unauthorized} =
               ClinicalRecord.assign_session_recording_speakers(
                 intruder,
                 patient.id,
                 recording.id,
                 %{0 => "patient"}
               )

      denials =
        Repo.all(
          from a in Audit,
            where:
              a.action == "clinical_record_access_denied" and a.professional_id == ^intruder.id
        )

      assert length(denials) == 6
      assert Repo.aggregate(SessionRecording, :count) == 1
      assert chunks(recording.id) == []
      assert Repo.get!(SessionRecording, recording.id).status == "recording"
    end

    test "a recording of another patient is not found and the denial is audited", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)
      other_patient = create_patient!(professional)

      assert {:error, :not_found} =
               ClinicalRecord.get_session_recording(professional, other_patient.id, recording.id)

      assert {:error, :not_found} =
               ClinicalRecord.append_session_recording_chunk(
                 professional,
                 other_patient.id,
                 recording.id,
                 0,
                 @audio
               )

      assert {:error, :not_found} =
               ClinicalRecord.finish_session_recording(
                 professional,
                 other_patient.id,
                 recording.id
               )

      assert [_, _, _] =
               Repo.all(
                 from a in Audit,
                   where:
                     a.action == "clinical_record_access_denied" and
                       a.resource_id == ^recording.id and
                       a.resource_type == "session_recording"
               )

      assert chunks(recording.id) == []
      assert Repo.get!(SessionRecording, recording.id).status == "recording"
    end
  end

  describe "append_session_recording_chunk/5" do
    test "stores each chunk encrypted with the patient's key, without auditing", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)
      append!(professional, patient, recording, 0, "AAA")
      append!(professional, patient, recording, 1, "BBB")

      dek = clinical_record_dek(professional, patient)

      assert [%{seq: 0} = first, %{seq: 1} = second] = chunks(recording.id)
      refute first.encrypted_data == "AAA"
      assert first.byte_size == 3
      assert {:ok, "AAA"} = PatientVault.decrypt(first.encrypted_data, dek)
      assert {:ok, "BBB"} = PatientVault.decrypt(second.encrypted_data, dek)

      assert Repo.aggregate(from(a in Audit, where: a.resource_id == ^recording.id), :count) ==
               1
    end

    test "resending a stored seq is acknowledged without storing it twice", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)
      append!(professional, patient, recording, 0, "AAA")
      append!(professional, patient, recording, 0, "AAA")

      assert [%{seq: 0}] = chunks(recording.id)
    end

    test "rejects a chunk over 512 KB and an empty or badly numbered chunk", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)
      too_big = :binary.copy("a", 512 * 1024 + 1)

      assert {:error, :chunk_too_large} =
               ClinicalRecord.append_session_recording_chunk(
                 professional,
                 patient.id,
                 recording.id,
                 0,
                 too_big
               )

      for {seq, data} <- [{0, ""}, {-1, "AAA"}, {"0", "AAA"}] do
        assert {:error, :invalid_chunk} =
                 ClinicalRecord.append_session_recording_chunk(
                   professional,
                   patient.id,
                   recording.id,
                   seq,
                   data
                 )
      end

      assert {:error, :recording_too_long} =
               ClinicalRecord.append_session_recording_chunk(
                 professional,
                 patient.id,
                 recording.id,
                 1_600,
                 "AAA"
               )

      assert chunks(recording.id) == []
    end

    test "is rejected once the recording is finished", %{
      professional: professional,
      patient: patient
    } do
      recording = create_recording!(professional, patient)

      assert {:error, :not_recording} =
               ClinicalRecord.append_session_recording_chunk(
                 professional,
                 patient.id,
                 recording.id,
                 1,
                 "late"
               )

      assert [%{seq: 0}] = chunks(recording.id)
    end
  end

  describe "finish_session_recording/3" do
    test "moves the recording to transcription and enqueues the worker", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)
      append!(professional, patient, recording, 0, @audio)
      Phoenix.PubSub.subscribe(Alethea.PubSub, SessionRecordings.topic(patient.id))

      assert {:ok, %SessionRecording{status: "transcribing"}} =
               ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)

      assert Repo.get!(SessionRecording, recording.id).status == "transcribing"
      assert [_chunk] = chunks(recording.id)

      assert_enqueued(
        worker: SessionTranscriptionWorker,
        args: %{"session_recording_id" => recording.id},
        queue: :transcription
      )

      assert_receive {:session_recording_updated, id} when id == recording.id
    end

    test "a recording without chunks fails as empty_recording", %{
      professional: professional,
      patient: patient
    } do
      recording = start_recording!(professional, patient)

      assert {:ok, %SessionRecording{status: "failed", error_code: "empty_recording"}} =
               ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)

      stored = Repo.get!(SessionRecording, recording.id)
      assert stored.status == "failed"
      assert stored.error_code == "empty_recording"
      assert [_] = audits("session_recording_failed", recording.id)
      refute_enqueued(worker: SessionTranscriptionWorker)
    end

    test "finishing twice fails the second time and enqueues one job", %{
      professional: professional,
      patient: patient
    } do
      recording = create_recording!(professional, patient)

      assert {:error, :invalid_status} =
               ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)

      assert [_job] = all_enqueued(worker: SessionTranscriptionWorker)
      assert Repo.get!(SessionRecording, recording.id).status == "transcribing"
    end
  end

  describe "list_session_recordings/2" do
    test "lists the patient's recordings only", %{professional: professional, patient: patient} do
      recording = create_recording!(professional, patient)
      _other = create_recording!(professional, create_patient!(professional))

      assert {:ok, [%SessionRecording{id: id}]} =
               ClinicalRecord.list_session_recordings(professional, patient.id)

      assert id == recording.id
    end
  end

  describe "speaker assignment" do
    setup %{professional: professional, patient: patient} do
      TranscriptionStub.install(@diarized)
      recording = create_recording!(professional, patient)
      :ok = perform_job(SessionTranscriptionWorker, %{"session_recording_id" => recording.id})
      %{recording: recording}
    end

    test "samples show two lines per speaker", %{
      professional: professional,
      patient: patient,
      recording: recording
    } do
      assert {:ok,
              [
                %{speaker: 0, samples: ["Hola, ¿cómo estás?", "Contame más."]},
                %{speaker: 1, samples: ["Mal.", "No dormí."]}
              ]} =
               ClinicalRecord.session_recording_speaker_samples(
                 professional,
                 patient.id,
                 recording.id
               )
    end

    test "two requests that both loaded the recording create only one transcript", %{
      professional: professional,
      patient: patient,
      recording: recording
    } do
      stale = Repo.get!(SessionRecording, recording.id)
      patient = Accounts.get_patient_for_professional(professional.id, patient.id)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)
      keyring = %{patient_dek: patient_dek, clinical_record_dek: record_dek}
      mapping = %{0 => "therapist", 1 => "patient"}

      assert {:ok, _} =
               SessionRecordings.assign_speakers(professional, patient, keyring, stale, mapping)

      assert {:error, :invalid_status} =
               SessionRecordings.assign_speakers(professional, patient, keyring, stale, mapping)

      assert Repo.aggregate(
               from(t in SessionTranscript, where: t.patient_id == ^patient.id),
               :count
             ) == 1
    end

    test "assign creates a transcript with the mapped speakers", %{
      professional: professional,
      patient: patient,
      recording: recording
    } do
      assert {:ok, %SessionRecording{status: "ready", session_transcript_id: transcript_id}} =
               ClinicalRecord.assign_session_recording_speakers(
                 professional,
                 patient.id,
                 recording.id,
                 %{"0" => "therapist", "1" => "patient"}
               )

      stored = Repo.get!(SessionRecording, recording.id)
      assert stored.session_transcript_id == transcript_id
      assert stored.encrypted_segments == nil
      assert chunks(recording.id) == []

      assert {:ok, %SessionTranscript{spans: spans, audio_duration_seconds: 42}} =
               ClinicalRecord.get_session_transcript(professional, patient.id, transcript_id)

      assert Enum.map(spans, &{&1.speaker, &1.text}) == [
               {"therapist", "Hola, ¿cómo estás?"},
               {"patient", "Mal."},
               {"therapist", "Contame más."},
               {"patient", "No dormí."},
               {"therapist", "Tercera línea."}
             ]

      assert [_] = audits("session_recording_speakers_assigned", recording.id)
      assert [_] = audits("session_transcript_created", transcript_id)

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{"event" => "session_transcript_created", "resource_id" => transcript_id}
      )
    end

    test "an incomplete or invalid mapping is rejected and changes nothing", %{
      professional: professional,
      patient: patient,
      recording: recording
    } do
      for mapping <- [
            %{0 => "therapist"},
            %{0 => "therapist", 1 => "doctor"},
            %{0 => "therapist", 1 => "patient", 2 => "patient"},
            %{"x" => "patient", 1 => "patient"}
          ] do
        assert {:error, :invalid_speaker_mapping} =
                 ClinicalRecord.assign_session_recording_speakers(
                   professional,
                   patient.id,
                   recording.id,
                   mapping
                 )
      end

      stored = Repo.get!(SessionRecording, recording.id)
      assert stored.status == "needs_speakers"
      assert is_binary(stored.encrypted_segments)
      assert Repo.aggregate(SessionTranscript, :count) == 0
      assert audits("session_recording_speakers_assigned", recording.id) == []
    end
  end

  describe "retry_session_recording/3" do
    test "a failed recording without audio cannot be retried", %{
      professional: professional,
      patient: patient
    } do
      TranscriptionStub.install({:error, :timeout})
      recording = create_recording!(professional, patient)

      :ok =
        perform_job(SessionTranscriptionWorker, %{"session_recording_id" => recording.id},
          attempt: 3
        )

      assert {:ok, %SessionRecording{status: "failed", audio_stored?: false}} =
               ClinicalRecord.get_session_recording(professional, patient.id, recording.id)

      assert {:error, :not_retryable} =
               ClinicalRecord.retry_session_recording(professional, patient.id, recording.id)
    end

    test "a failed recording that still holds audio is re-enqueued", %{
      professional: professional,
      patient: patient
    } do
      recording = create_recording!(professional, patient)

      recording
      |> SessionRecording.transition_changeset(%{status: "failed", error_code: "provider_error"})
      |> Repo.update!()

      assert {:ok, %SessionRecording{audio_stored?: true} = failed} =
               ClinicalRecord.get_session_recording(professional, patient.id, recording.id)

      assert SessionRecordings.retryable?(failed)

      assert {:ok, %SessionRecording{status: "transcribing", error_code: nil}} =
               ClinicalRecord.retry_session_recording(professional, patient.id, recording.id)

      # The first job is still pending, so uniqueness keeps a single one.
      assert [_job] = all_enqueued(worker: SessionTranscriptionWorker)
      assert Repo.get!(SessionRecording, recording.id).status == "transcribing"
    end
  end
end
