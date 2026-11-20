# Session recording

Record or upload a therapy session from the patient's page. The audio is transcribed in the background and the transcript joins the patient's clinical record, so the RAG consultation can answer from it and cite it.

Page: `/patients/:patient_id/sessions`, linked as **Sesiones grabadas** from the patient's dashboard actions. Only the professional who treats the patient can open it.

## Flow

1. **Consent.** Check "El paciente dio su consentimiento para grabar la sesión". Recording and file upload stay disabled until then.
2. **Capture.** Either:
   - **Grabar / Pausar / Finalizar** records audio in the browser (MediaRecorder; `audio/webm;codecs=opus`, falling back to `audio/mp4`), or
   - pick an audio file (webm, ogg, mp3, m4a, wav, mp4; up to 300 MB).

   Both go through a LiveView upload. When the upload finishes, the recording is saved and appears in the list as **Transcribiendo**.
3. **Transcription** runs in Oban (`AletheaJobs.SessionTranscriptionWorker`, queue `transcription`, 3 attempts) through the configured transcription provider (see [transcription-providers.md](transcription-providers.md)). The list updates live.
4. **Result:**
   - Two or more speakers detected → **Falta identificar hablantes**. Click **Identificar hablantes**: each speaker shows two sample lines; mark each one as **Vos (profesional)** or **Paciente** (extra voices can be marked as either). Saving creates the transcript.
   - One speaker or none → the transcript is created directly, with every line labelled **Sesión** (speaker `"unknown"`).
   - The provider failed on every attempt, or no speech was found → **Falló**, with the reason.
5. **Ready** recordings show **Ver transcripción**: each line with its `mm:ss` start and speaker label.

When transcription is not configured (`WHISPER_ENABLED` off), the page says so and capture stays disabled.

## Data and security

- Table `session_recordings`: status (`transcribing | needs_speakers | ready | failed`), content type, recording time, duration, consent timestamp, link to the created `session_transcripts` row, and an error code (never provider text).
- Audio and diarized segments are encrypted with the patient's clinical-record key.
- **The audio is deleted** after a successful transcription and after the last failed attempt. A failed recording can be retried only while its audio is still stored; otherwise record or upload again.
- Diarized segments are deleted once speakers are assigned.
- The transcript is created through `ClinicalRecord.create_session_transcript/3` (encryption, audit, RAG indexing).
- Audit actions (no content): `session_recording_created`, `session_recording_transcribed`, `session_recording_speakers_assigned`, `session_recording_failed`; cross-patient access writes `clinical_record_access_denied`.
- Audio and transcript text are never logged.

## Code

- Domain: `Alethea.ClinicalRecord` (`create_session_recording/3`, `list_session_recordings/2`, `get_session_recording/3`, `session_recording_speaker_samples/3`, `assign_session_recording_speakers/4`, `retry_session_recording/3`, `process_session_recording/2`), workflow in `Alethea.ClinicalRecord.SessionRecordings`, schema `Alethea.ClinicalRecord.SessionRecording`.
- Worker: `AletheaJobs.SessionTranscriptionWorker`.
- UI: `AletheaWeb.SessionRecordingLive.Index` and the `SessionRecorder` hook in `priv/static/assets/js/app.js`.
