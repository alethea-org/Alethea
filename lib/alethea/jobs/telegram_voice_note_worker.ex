defmodule Alethea.Jobs.TelegramVoiceNoteWorker do
  @moduledoc """
  Transcribes a patient's Telegram voice note and hands the transcript to
  the text pipeline (odd/tasks/telegram-voice-notes.md, S1-S4).

  `Alethea.Jobs.TelegramMessageWorker` enqueues this job for a linked
  patient's `voice` / `audio` update. The job:

    1. Answers with fixed copy, without downloading, when transcription
       is disabled (`Alethea.AI.enabled?(:ai_whisper)` is false), when
       the patient is over their transcription cap, or when the note is
       too large: longer than 10 minutes (Telegram `duration`), a
       `file_size` above `:max_file_bytes`, or neither field present (a
       note nothing bounds is never downloaded).
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

  ## Bounds (security audit run-1, S7)

  Speech-to-text is paid per call and any linked chat can send notes, so
  each patient is bounded, configured under
  `config :alethea, Alethea.Jobs.TelegramVoiceNoteWorker`:

    * `:max_file_bytes` (default 20 MB) — checked against Telegram's
      `file_size` before download, and against the downloaded bytes
      before transcription.
    * `:max_notes_per_window` (default 30) per `:window_seconds` (default
      3600) — counted over this worker's jobs for the same `patient_id`
      inserted in the rolling window before this one (no extra table).
      Every enqueued note counts, rejected ones included. A note over the
      cap is not downloaded; the patient gets the rate-limit copy. Jobs
      enqueued before `patient_id` was added to the args are not capped.

  ## Queue + uniqueness

  Own `:telegram_voice` queue: speech-to-text calls are slow and must not
  hold `:telegram_inbound` slots, and patient-triggered notes must not
  take the `:transcription` slots that professionals' session recordings
  use. `max_attempts: 3`, unique for 24h per `telegram_update_id` like
  the message worker, so a redelivered update is transcribed once.

  ## PHI hygiene

  `new/2` seals the Telegram `message` map into `"encrypted_message"`
  (`Alethea.Telegram.JobPayload`); `telegram_update_id` and `patient_id`
  stay in clear for uniqueness and the cap. Old plaintext `"message"`
  args are still accepted.

  The download URL embeds the bot token; the transcript is the patient's
  words. Log lines carry only the chat hash prefix and a bounded reason
  tag, and the error returned to Oban (persisted in `oban_jobs.errors`)
  is that same tag.
  """

  use Oban.Worker,
    queue: :telegram_voice,
    max_attempts: 3,
    unique: [period: 86_400, keys: [:telegram_update_id]]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Alethea.AI
  alias Alethea.Jobs.TelegramMessageWorker
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, JobPayload, LogRedactor}

  @max_duration_seconds 600
  @default_max_file_bytes 20 * 1024 * 1024
  @default_max_notes_per_window 30
  @default_window_seconds 3600
  @default_mime_type "audio/ogg"

  @disabled_copy "Por ahora solo puedo leer mensajes escritos. ¿Me lo contás por texto?"
  @too_long_copy "El audio es muy largo. ¿Podés mandarlo en partes más cortas o escribirlo?"
  @unheard_copy "No pude escuchar bien el audio. ¿Me lo podés escribir?"
  @rate_limited_copy "Recibí muchos audios en poco tiempo. ¿Me lo contás por texto por ahora?"

  @doc """
  Builds the job changeset with the Telegram `message` map sealed (see
  "PHI hygiene" in the moduledoc).
  """
  @impl Oban.Worker
  def new(args, opts) when is_map(args) and is_list(opts) do
    args
    |> JobPayload.seal_fields([:message])
    |> super(opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts} = job) do
    message = JobPayload.fetch!(args, :message)
    voice = TelegramMessageWorker.voice_payload(message)

    cond do
      not AI.enabled?(:ai_whisper) ->
        TelegramMessageWorker.send_voice_notice(message, @disabled_copy)

      over_patient_cap?(job) ->
        log(message, "over the per-patient transcription cap")
        TelegramMessageWorker.send_voice_notice(message, @rate_limited_copy)

      too_large?(voice) ->
        TelegramMessageWorker.send_voice_notice(message, @too_long_copy)

      true ->
        transcribe(message, voice, attempt >= max_attempts)
    end
  end

  # Large notes are bounded by the duration and size caps; this bounds
  # download + provider latency for the whole job.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # A note is admitted only when something bounds it: a known duration
  # within the cap or a known file size within the cap. Both are checked
  # when present; a note with neither is rejected rather than downloaded.
  defp too_large?(voice) do
    duration = Map.get(voice, "duration")
    file_size = Map.get(voice, "file_size")

    cond do
      is_integer(duration) and duration > @max_duration_seconds -> true
      is_integer(file_size) and file_size > max_file_bytes() -> true
      is_integer(duration) or is_integer(file_size) -> false
      true -> true
    end
  end

  # Counts this worker's jobs for the same patient inserted within the
  # window before this one. Jobs without a `patient_id` (enqueued before
  # the cap existed) are not capped.
  defp over_patient_cap?(%Oban.Job{args: args} = job) do
    case Map.get(args, "patient_id") || Map.get(args, :patient_id) do
      patient_id when is_binary(patient_id) ->
        earlier_jobs_in_window(job, patient_id) >= max_notes_per_window()

      _no_patient ->
        false
    end
  end

  defp earlier_jobs_in_window(%Oban.Job{id: job_id}, patient_id) do
    since = DateTime.add(DateTime.utc_now(), -window_seconds(), :second)
    worker = inspect(__MODULE__)

    query =
      from(j in Oban.Job,
        where:
          j.worker == ^worker and
            fragment("? @> ?", j.args, ^%{"patient_id" => patient_id}) and
            j.inserted_at >= ^since,
        select: count(j.id)
      )

    query =
      if is_integer(job_id), do: from(j in query, where: j.id < ^job_id), else: query

    Repo.one(query)
  end

  defp config, do: Application.get_env(:alethea, __MODULE__, [])

  defp max_file_bytes, do: Keyword.get(config(), :max_file_bytes, @default_max_file_bytes)

  defp max_notes_per_window,
    do: Keyword.get(config(), :max_notes_per_window, @default_max_notes_per_window)

  defp window_seconds, do: Keyword.get(config(), :window_seconds, @default_window_seconds)

  defp transcribe(message, voice, final_attempt?) do
    content_type = Map.get(voice, "mime_type") || @default_mime_type

    with {:ok, audio} <- telegram_client().download_file(Map.fetch!(voice, "file_id")),
         :ok <- check_downloaded_size(audio),
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
      {:error, :file_too_large} ->
        log(message, "not transcribed (reason=:file_too_large)")
        TelegramMessageWorker.send_voice_notice(message, @too_long_copy)

      {:error, reason} ->
        tag = reason_tag(reason)
        log(message, "not transcribed (reason=#{inspect(tag)}, final=#{final_attempt?})")

        if final_attempt?,
          do: TelegramMessageWorker.send_voice_notice(message, @unheard_copy),
          else: {:error, tag}
    end
  end

  # The declared `file_size` is optional, so the downloaded bytes are
  # bounded again before they reach the paid provider.
  defp check_downloaded_size(audio) when is_binary(audio) do
    if byte_size(audio) > max_file_bytes(), do: {:error, :file_too_large}, else: :ok
  end

  defp check_downloaded_size(_audio), do: :ok

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
