# Telegram voice notes

A patient can send the bot a voice note (or an audio file) instead of
writing. The bot transcribes it and handles the transcript exactly like a
written message.

## Flow

1. The webhook enqueues `Alethea.Jobs.TelegramMessageWorker` as for any
   update (nothing is downloaded during the webhook request).
2. For a linked patient, a textless update with a `voice` or `audio`
   payload is handed to `Alethea.Jobs.TelegramVoiceNoteWorker` on the
   `:transcription` Oban queue (3 attempts, unique per `update_id`).
3. That job downloads the file through the Telegram client
   (`getFile`, then the file download) and transcribes it with
   `Alethea.AI.whisper()` (`language: "es"`, content type from Telegram's
   `mime_type`, default `audio/ogg`).
4. The transcript goes through
   `TelegramMessageWorker.process_voice_transcript/2`: the same
   persistence (encrypted), emotion analysis, crisis detection, reactive
   triggers, burst reply and session handling as a written message.
5. The stored inbound message has `media_type: "voice"`, and the
   professional's chat history shows a "Nota de voz" label on it.

The audio is never persisted nor logged; it only exists in the job's
memory while it is transcribed. Log lines and Oban errors carry only the
chat hash prefix and a bounded reason tag (the file URL contains the bot
token).

## Fixed replies

These never reach the AI reply pipeline and store no message:

| Case | Reply |
| --- | --- |
| Transcription disabled (`AI.enabled?(:ai_whisper)` false) | "Por ahora solo puedo leer mensajes escritos. ¿Me lo contás por texto?" |
| Note longer than 10 minutes (Telegram `duration` > 600 s), not downloaded | "El audio es muy largo. ¿Podés mandarlo en partes más cortas o escribirlo?" |
| Download or transcription failed on the last attempt, or empty transcript | "No pude escuchar bien el audio. ¿Me lo podés escribir?" |

Earlier failed attempts are retried by Oban without replying.

## Other media

Photos, stickers and documents without a caption are still dropped, as
before.

## Configuration

Transcription uses the provider configured for session recordings; see
`docs/features/transcription-providers.md`. With the provider disabled,
patients get the first fixed reply above.
