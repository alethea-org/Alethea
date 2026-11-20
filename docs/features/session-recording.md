# Session recording

Record a therapy session from the patient's page. The audio streams to the server while you record, is transcribed in the background, and the transcript joins the patient's clinical record, so the RAG consultation can answer from it and cite it.

Page: `/patients/:patient_id/sessions`, linked as **Sesiones grabadas** from the patient's dashboard actions. Only the professional who treats the patient can open it.

There is no file upload: sessions are recorded only inside the system.

## Flow

1. **Consent.** Check "El paciente dio su consentimiento para grabar la sesión". **Grabar** stays disabled until then.
2. **Record.** **Grabar / Pausar / Reanudar / Finalizar**. The browser records mono Opus (`audio/webm;codecs=opus` at ~24 kbps, about 11 MB per hour; Safari falls back to `audio/mp4`) and sends a chunk about every 10 seconds. Each chunk is stored encrypted as soon as it arrives and acknowledged; next to the timer, **guardado hasta mm:ss** shows how much audio is already safe on the server.
   - If the connection drops, unacknowledged chunks stay queued in the browser and are resent in order when LiveView reconnects (a chunk is never sent before the previous one was acknowledged; resending a stored chunk is harmless).
   - Closing the tab while recording asks for confirmation. Whatever was already sent is kept.
   - **Finalizar** waits until every chunk is acknowledged, then hands the recording to transcription. The list shows **Grabando…** while recording; a recording left by a previous page load shows "Grabación interrumpida: se procesará automáticamente".
3. **Transcription** runs in Oban (`AletheaJobs.SessionTranscriptionWorker`, queue `transcription`, 3 attempts) through the configured transcription provider (see [transcription-providers.md](transcription-providers.md)). The chunks are decrypted and concatenated in order into one audio file. The list updates live.
4. **Result:**
   - Two or more speakers detected → **Falta identificar hablantes**. Click **Identificar hablantes**: each speaker shows two sample lines; mark each one as **Vos (profesional)** or **Paciente** (extra voices can be marked as either). Saving creates the transcript.
   - One speaker or none → the transcript is created directly, with every line labelled **Sesión** (speaker `"unknown"`).
   - The provider failed on every attempt, no speech was found, or the recording had no audio → **Falló**, with the reason.
5. **Ready** recordings show **Ver transcripción**: each line with its `mm:ss` start and speaker label.

When transcription is not configured (`WHISPER_ENABLED` off), the page says so and recording stays disabled.

## Limits

- A chunk may be at most 512 KB (a 10 s chunk at 24 kbps is ~30 KB).
- A recording may hold at most 1,600 chunks and 60 MB of audio (about four hours).
- Only `audio/webm` and `audio/mp4` are accepted.

## Cleanup

`AletheaJobs.SessionRecordingCleanupWorker` runs every 10 minutes (Oban Cron, queue `transcription`):

- A recording still **recording** with no chunk for **15 minutes** (tab closed, connection lost) is finished automatically: transcribed if it has audio, failed (`empty_recording`) otherwise.
- A recording **transcribing** for **30 minutes** without a live transcription job (the job crashed or timed out on its last attempt) is marked failed (`stalled`) and its audio deleted.

Nothing stays forever with encrypted audio.

## Data and security

- Table `session_recordings`: status (`recording | transcribing | needs_speakers | ready | failed`), content type, recording time, duration, consent timestamp, link to the created `session_transcripts` row, and an error code (never provider text).
- Table `session_recording_chunks`: one row per streamed chunk (`seq`, encrypted data, plaintext size), unique per recording and `seq`.
- Audio chunks and diarized segments are encrypted with the patient's clinical-record key.
- **The audio chunks are deleted** after a successful transcription, after the last failed attempt, and when cleanup fails a stalled recording. A failed recording can be retried only while its audio is still stored; otherwise record again.
- Diarized segments are deleted once speakers are assigned.
- The transcript is created through `ClinicalRecord.create_session_transcript/3` (encryption, audit, RAG indexing).
- Audit actions (no content): `session_recording_created`, `session_recording_transcribed`, `session_recording_speakers_assigned`, `session_recording_failed`; cross-patient access writes `clinical_record_access_denied`. Chunks are not audited one by one.
- Every chunk and finish request is checked against the professional and patient; the recording id alone is never trusted.
- Audio and transcript text are never logged.

## Code

- Domain: `Alethea.ClinicalRecord` (`start_session_recording/3`, `append_session_recording_chunk/5`, `finish_session_recording/3`, `list_session_recordings/2`, `get_session_recording/3`, `session_recording_speaker_samples/3`, `assign_session_recording_speakers/4`, `retry_session_recording/3`, `process_session_recording/2`, `clean_up_session_recordings/3`), workflow in `Alethea.ClinicalRecord.SessionRecordings`, schemas `Alethea.ClinicalRecord.SessionRecording` and `Alethea.ClinicalRecord.SessionRecordingChunk`.
- Workers: `AletheaJobs.SessionTranscriptionWorker`, `AletheaJobs.SessionRecordingCleanupWorker`.
- UI: `AletheaWeb.SessionRecordingLive.Index` and the `SessionRecorder` hook in `priv/static/assets/js/app.js` (events `start`, `chunk`, `finish`).
