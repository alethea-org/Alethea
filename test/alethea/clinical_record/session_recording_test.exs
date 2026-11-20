defmodule Alethea.ClinicalRecord.SessionRecordingTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{Audit, SessionRecording, SessionRecordings, SessionTranscript}
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

  defp create_recording!(professional, patient) do
    {:ok, recording} =
      ClinicalRecord.create_session_recording(professional, patient.id, %{
        audio: @audio,
        content_type: "audio/webm",
        consent: true
      })

    recording
  end

  defp clinical_record_dek(professional, patient) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.ensure_clinical_record_dek(patient, kek)
    dek
  end

  defp audits(action, recording_id) do
    Repo.all(from a in Audit, where: a.action == ^action and a.resource_id == ^recording_id)
  end

  describe "create_session_recording/3" do
    test "stores the audio encrypted, audits and enqueues transcription", %{
      professional: professional,
      patient: patient
    } do
      Phoenix.PubSub.subscribe(Alethea.PubSub, SessionRecordings.topic(patient.id))
      recording = create_recording!(professional, patient)

      stored = Repo.get!(SessionRecording, recording.id)
      assert stored.status == "transcribing"
      assert stored.content_type == "audio/webm"
      assert stored.patient_id == patient.id
      assert stored.professional_id == professional.id
      assert %DateTime{} = stored.consent_confirmed_at
      refute stored.encrypted_audio == @audio

      assert {:ok, @audio} =
               PatientVault.decrypt(
                 stored.encrypted_audio,
                 clinical_record_dek(professional, patient)
               )

      assert [%Audit{professional_id: prof_id, resource_type: "session_recording"} = audit] =
               audits("session_recording_created", recording.id)

      assert prof_id == professional.id
      assert audit.details == %{"outcome" => "success"}

      assert_enqueued(
        worker: SessionTranscriptionWorker,
        args: %{"session_recording_id" => recording.id},
        queue: :transcription
      )

      assert_receive {:session_recording_updated, id} when id == recording.id
    end

    test "requires consent and stores nothing without it", %{
      professional: professional,
      patient: patient
    } do
      assert {:error, :consent_required} =
               ClinicalRecord.create_session_recording(professional, patient.id, %{
                 audio: @audio,
                 content_type: "audio/webm"
               })

      assert Repo.aggregate(SessionRecording, :count) == 0
      refute_enqueued(worker: SessionTranscriptionWorker)
    end

    test "another professional cannot create, list, get or assign", %{
      professional: professional,
      patient: patient
    } do
      recording = create_recording!(professional, patient)
      intruder = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.create_session_recording(intruder, patient.id, %{
                 audio: @audio,
                 content_type: "audio/webm",
                 consent: true
               })

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

      assert length(denials) == 4
      assert Repo.aggregate(SessionRecording, :count) == 1
    end

    test "a recording of another patient is not found and the denial is audited", %{
      professional: professional,
      patient: patient
    } do
      recording = create_recording!(professional, patient)
      other_patient = create_patient!(professional)

      assert {:error, :not_found} =
               ClinicalRecord.get_session_recording(professional, other_patient.id, recording.id)

      assert [%Audit{resource_type: "session_recording"}] =
               Repo.all(
                 from a in Audit,
                   where:
                     a.action == "clinical_record_access_denied" and
                       a.resource_id == ^recording.id
               )
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
      assert stored.encrypted_audio == nil

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

      assert {:ok, %SessionRecording{status: "transcribing", error_code: nil}} =
               ClinicalRecord.retry_session_recording(professional, patient.id, recording.id)

      assert_enqueued(
        worker: SessionTranscriptionWorker,
        args: %{"session_recording_id" => recording.id}
      )
    end
  end
end
