defmodule Alethea.Jobs.TelegramVoiceNoteWorker do
  @moduledoc """
  Transcribes a patient's Telegram voice note and hands the transcript to
  the text pipeline (odd/tasks/telegram-voice-notes.md, S1-S4).

  `Alethea.Jobs.TelegramMessageWorker` enqueues this job for a linked
  patient's `voice` / `audio` update. The job:

    1. Answers with fixed copy, without downloading, when transcription
       is disabled (`Alethea.AI.enabled?(:ai_whisper)` is false) or the
       note is longer than 10 minutes (Telegram `duration`).
    2. Downloads the file through the configured Telegram client
       (`getFile` + file download) and transcribes it with
       `Alethea.AI.whisper()` (`language: "es"`, content type from
       Telegram's `mime_type`, default `audio/ogg`). The audio only lives
       in this process's memory: it is never persisted nor logged.
    3. Feeds the transcript to
       `TelegramMessageWorker.process_voice_transcript/2`, the same path a
       written message takes, which stores it marked as a voice note.

  A failed download or transcription returns `{:error, reason}` so Oban
  retries it; on the final attempt, and for an empty transcript, the
  patient gets the "could not hear it" copy once instead.

  ## Queue + uniqueness

  `:transcription` queue (speech-to-text calls are slow and must not hold
  `:telegram_inbound` slots), `max_attempts: 3`, unique for 24h per
  `telegram_update_id` like the message worker, so a redelivered update
  is transcribed once.

  ## PHI hygiene

  The download URL embeds the bot token; the transcript is the patient's
  words. Log lines carry only the chat hash prefix and a bounded reason
  tag, and the error returned to Oban (persisted in `oban_jobs.errors`)
  is that same tag.
  """

  use Oban.Worker,
    queue: :transcription,
    max_attempts: 3,
    unique: [period: 86_400, keys: [:telegram_update_id]]

  require Logger

  alias Alethea.AI
  alias Alethea.Jobs.TelegramMessageWorker
  alias Alethea.Telegram.{ChatIdHash, LogRedactor}

  @max_duration_seconds 600
  @default_mime_type "audio/ogg"

  @disabled_copy "Por ahora solo puedo leer mensajes escritos. ¿Me lo contás por texto?"
  @too_long_copy "El audio es muy largo. ¿Podés mandarlo en partes más cortas o escribirlo?"
  @unheard_copy "No pude escuchar bien el audio. ¿Me lo podés escribir?"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    message = Map.get(args, "message") || Map.fetch!(args, :message)
    voice = TelegramMessageWorker.voice_payload(message)

    cond do
      not AI.enabled?(:ai_whisper) ->
        TelegramMessageWorker.send_voice_notice(message, @disabled_copy)

      too_long?(voice) ->
        TelegramMessageWorker.send_voice_notice(message, @too_long_copy)

      true ->
        transcribe(message, voice, attempt >= max_attempts)
    end
  end

  # Large notes are bounded by the 10-minute cap; this bounds download +
  # provider latency for the whole job.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  defp too_long?(%{"duration" => duration}) when is_integer(duration),
    do: duration > @max_duration_seconds

  defp too_long?(_voice), do: false

  defp transcribe(message, voice, final_attempt?) do
    content_type = Map.get(voice, "mime_type") || @default_mime_type

    with {:ok, audio} <- telegram_client().download_file(Map.fetch!(voice, "file_id")),
         {:ok, transcription} <-
           AI.whisper().transcribe(audio, content_type: content_type, language: "es") do
      case transcript(transcription) do
        "" ->
          log(message, "empty transcript")
          TelegramMessageWorker.send_voice_notice(message, @unheard_copy)

        text ->
          TelegramMessageWorker.process_voice_transcript(message, text)
      end
    else
      {:error, reason} ->
        tag = reason_tag(reason)
        log(message, "not transcribed (reason=#{inspect(tag)}, final=#{final_attempt?})")

        if final_attempt?,
          do: TelegramMessageWorker.send_voice_notice(message, @unheard_copy),
          else: {:error, tag}
    end
  end

  defp transcript(%{text: text}) when is_binary(text), do: String.trim(text)
  defp transcript(_transcription), do: ""

  # A bounded, content-free description of the failure: never the URL,
  # the response body or the provider's message.
  defp reason_tag(reason) when is_atom(reason), do: reason

  defp reason_tag({tag, detail}) when is_atom(tag) and (is_atom(detail) or is_integer(detail)),
    do: {tag, detail}

  defp reason_tag(tuple) when is_tuple(tuple) and is_atom(elem(tuple, 0)), do: elem(tuple, 0)
  defp reason_tag(_reason), do: :unknown

  defp log(%{"chat" => %{"id" => chat_id}}, event) do
    pepper = Application.fetch_env!(:alethea, :telegram_chat_id_pepper)
    hash_prefix = chat_id |> ChatIdHash.hash(pepper) |> LogRedactor.prefix()
    Logger.warning("TelegramVoiceNoteWorker: voice note #{event} (hash_prefix=#{hash_prefix})")
  end

  defp telegram_client do
    Application.get_env(:alethea, :telegram_client, Alethea.Telegram.Client.Fake)
  end
end
