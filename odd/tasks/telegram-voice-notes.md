# Telegram voice notes from patients

Objective: a patient's voice note (or audio) sent to the bot is transcribed with the provider-agnostic transcription adapter and then handled exactly like a text message. Branch `feat/telegram-voice-notes` (stacked on `feat/session-recording`). Delivery: ask-on-risk. Runner: `mix test` / `mix precommit`.

## Specs

- S1 "vamos con las notas de voz del paciente en telegram". Telegram `voice` (and `audio`) messages from a linked patient are no longer dropped: the worker downloads the file via the Bot API (`getFile` + file download), transcribes it with `Alethea.AI.whisper()` (`language: "es"`, content type from Telegram's `mime_type`, default `audio/ogg`), discards the audio (never persisted, never logged), and feeds the transcript text through the same pipeline as a text message: persistence (encrypted), emotion analysis, crisis detection, reactive triggers, burst/reply logic, session handling.
- S2 The stored message is marked as a voice note (reuse an existing `media_type` field if the schema has one; otherwise the smallest additive change) and the professional's chat history shows a "Nota de voz" label on it.
- S3 Edge cases, Spanish replies from the bot, no AI reply generated for them:
  - Transcription disabled (`AI.enabled?(:ai_whisper)` false): "Por ahora solo puedo leer mensajes escritos. ¿Me lo contás por texto?"
  - Voice longer than 10 minutes (Telegram `duration`): "El audio es muy largo. ¿Podés mandarlo en partes más cortas o escribirlo?"
  - Transcription failed after retries or empty transcript: "No pude escuchar bien el audio. ¿Me lo podés escribir?"
- S4 Downloads and transcription run in Oban (never in the webhook request); transient errors retry; the Telegram file URL contains the bot token and must never be logged.
- S5 Other non-text messages (photos, stickers, documents) keep today's behavior.

## Tasks

- T1 S1-S5 — delegated (writer; parent context at long-session backstop)

## Log

- L1 (2026-11-20) "vamos con las notas de voz del paciente en telegram"
- L2 Plan accepted implicitly by the request; audio never stored (consistent with the session-recording decision "Delete after transcribing").
