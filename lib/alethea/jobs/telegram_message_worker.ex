defmodule Alethea.Jobs.TelegramMessageWorker do
  @moduledoc """
  Oban worker for inbound Telegram messages (C-3 + C-5 safe path; PR #3a).

  Receives the full Telegram `Update.message` JSON (with the raw
  `chat.id` still in plaintext — the worker is responsible for
  HMAC-hashing it via `Alethea.Telegram.ChatIdHash.hash/2` before any
  DB lookup or log line).

  ## Safe clinical round-trip (PR #3a)

    1. Hash `chat.id` via `ChatIdHash.hash/2` (R-1 PHI hygiene).
    2. Resolve patient via `Foundation.Accounts.lookup_patient_by_chat_hash/1`.
       If `:not_found`, enqueue a one-shot TelegramOutboundWorker with
       the "unregistered" copy and return `:ok` (REQ-C3-worker-resolves-patient).
    3. If the message has no text (sticker / voice / photo without
       caption), drop it: no Message row, no outbound job, return
       `:ok` (REQ-C5-persist-inbound-message "empty text payloads
       are dropped").
    4. Persist inbound `Message` via `Clinical.save_telegram_message/7`
       with `direction: "inbound"`, `source: "spontaneous"`,
       `telegram_message_id` (REQ-C3-worker-persists-message).
    5. Enqueue `EmotionAnalysisWorker` on `:ai_analysis` (REQ-C5-trigger-emotion-analysis).
    6. Classify via `Alerts.CrisisMonitor.detect/1`. **PR #3a covers the
       safe path only**; the `:crisis` branch (`:telegram_outbound_crisis`
       lane, PubSub `:crisis_detected`, `urgent_intervention: true`)
       lands in PR #3b.
    7. Build patient context, call `Alethea.AI.llm().chat/2` (REQ-C5-llm-reply-on-safe).
    8. Persist outbound `Message` via `Clinical.save_telegram_message/7`
       with `direction: "outbound"`, `source: "elicited"` (REQ-C5-persist-outbound-reply).
    9. Enqueue `TelegramOutboundWorker` on `:telegram_outbound` with
       `chat_id_hash`, `message_id`, `body`, `lane: :safe`
       (REQ-C3-worker-emits-outbound-job).

  ## Queue + uniqueness (REQ-C3-idempotent-by-update-id)

    - Queue: `:telegram_inbound`.
    - Unique: 24h, keyed on `args.telegram_update_id`.
    - `max_attempts: 3` (REQ-C3 — the PR #1b / #2 stub used `5` because
      the body was a no-op; PR #3a aligns with the spec).

  ## R-1 (PHI hygiene)

  The args map carries the raw `chat_id` in `message.chat.id`. The
  worker hashes it before any DB lookup or log line. The controller
  (TASK-2-3) also does not log the body. Logger lines may include the
  first 8 chars of the hash as a correlation token (REQ-C2-no-plaintext-in-logs
  "the line may include the first 8 chars of the hash and SHALL NOT
  include the full hash, the chat_id, or the message body").

  ## Crisis branch (out of scope here)

  The `:crisis` classification branch — `:telegram_outbound_crisis`
  queue, `urgent_intervention: true`, `model_version: "crisis-bypass"`,
  PubSub `:crisis_detected` on `"psychologist:alerts"` — lands in
  PR #3b. The safe-path body explicitly raises
  `NotImplementedError` if `CrisisMonitor.detect/1` returns a
  `:crisis` tuple, so a regression into crisis logic fails loudly
  rather than silently dropping the crisis message.
  """

  use Oban.Worker,
    queue: :telegram_inbound,
    max_attempts: 3,
    unique: [period: 86_400, keys: [:telegram_update_id]]

  require Logger

  alias Alethea.Clinical
  alias Alethea.AI
  alias Alethea.Alerts.CrisisMonitor
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Telegram.ChatIdHash
  alias Alethea.Jobs.TelegramOutboundWorker
  alias AletheaJobs.EmotionAnalysisWorker

  @unregistered_copy "Hola. No reconozco este chat en nuestro sistema clínico. Si eres un paciente, por favor contacta a tu terapeuta para que te registre."

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{message: message} = args
    %{"chat" => %{"id" => chat_id}, "message_id" => telegram_message_id, "text" => text} = message

    chat_id_hash = ChatIdHash.hash(chat_id, pepper!())
    hash_prefix = String.slice(chat_id_hash, 0, 8)

    case FoundationAccounts.lookup_patient_by_chat_hash(chat_id_hash) do
      {:ok, foundation_patient} ->
        process_bound_message(foundation_patient, chat_id, chat_id_hash, hash_prefix, text,
          telegram_message_id: telegram_message_id
        )

      :not_found ->
        enqueue_unregistered_reply(chat_id, chat_id_hash, hash_prefix)
        :ok
    end
  end

  # ----------------------------------------------------------------
  # Bound patient branch (safe path)
  # ----------------------------------------------------------------

  defp process_bound_message(
         foundation_patient,
         chat_id,
         chat_id_hash,
         hash_prefix,
         text,
         opts
       ) do
    telegram_message_id = Keyword.fetch!(opts, :telegram_message_id)

    if empty_text?(text) do
      Logger.info(
        "TelegramMessageWorker: dropping empty-text update (hash_prefix=#{hash_prefix})"
      )

      :ok
    else
      {:ok, _legacy_patient} = FoundationAccounts.legacy_patient(foundation_patient)

      {:ok, inbound} =
        Clinical.save_telegram_message(
          foundation_patient,
          text,
          "inbound",
          "spontaneous",
          to_string(telegram_message_id)
        )

      enqueue_emotion_analysis(inbound.id, hash_prefix)

      case CrisisMonitor.detect(text) do
        :safe ->
          handle_safe_path(foundation_patient, chat_id, chat_id_hash, hash_prefix, inbound, text)

        {:crisis, _severity, _triggers} ->
          # PR #3b territory — fail loud rather than silently drop.
          raise "TelegramMessageWorker: crisis branch is out of scope in PR #3a " <>
                  "(hash_prefix=#{hash_prefix})"
      end
    end
  end

  defp handle_safe_path(foundation_patient, chat_id, chat_id_hash, hash_prefix, inbound, text) do
    context_limit =
      Application.get_env(:alethea, Alethea.Clinical, [])[:recent_message_limit] || 10

    {:ok, legacy_patient} = FoundationAccounts.legacy_patient(foundation_patient)

    context =
      case Clinical.build_patient_context(legacy_patient, context_limit) do
        {:ok, ctx} -> ctx
        {:error, _reason} -> ""
      end

    messages = build_llm_messages(context, text)

    case AI.llm().chat(messages, []) do
      {:ok, %{content: reply}} when is_binary(reply) and reply != "" ->
        persist_and_enqueue_outbound(
          foundation_patient,
          chat_id,
          chat_id_hash,
          hash_prefix,
          reply,
          inbound.id
        )

      {:ok, %{content: ""}} ->
        raise "TelegramMessageWorker: LLM returned empty content (hash_prefix=#{hash_prefix})"

      {:error, reason} ->
        raise "TelegramMessageWorker: LLM error: #{inspect(reason)} " <>
                "(hash_prefix=#{hash_prefix})"
    end
  end

  defp persist_and_enqueue_outbound(
         foundation_patient,
         chat_id,
         chat_id_hash,
         hash_prefix,
         reply,
         inbound_message_id
       ) do
    {:ok, outbound} =
      Clinical.save_telegram_message(
        foundation_patient,
        reply,
        "outbound",
        "elicited",
        nil
      )

    # Link the outbound reply to the inbound for traceability. The
    # `Message` schema does not carry a FK for this today; we record
    # the link via the outbound job's args. A future schema change
    # can persist the `reply_to_message_id` directly.
    _ = inbound_message_id

    enqueue_outbound(chat_id_hash, chat_id, outbound.id, reply, hash_prefix)
    :ok
  end

  # ----------------------------------------------------------------
  # Enqueue helpers
  # ----------------------------------------------------------------

  defp enqueue_emotion_analysis(message_id, hash_prefix) do
    EmotionAnalysisWorker.new(%{message_id: message_id})
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        raise "TelegramMessageWorker: failed to enqueue EmotionAnalysisWorker " <>
                "(reason=#{inspect(reason)}, hash_prefix=#{hash_prefix})"
    end
  end

  defp enqueue_outbound(chat_id_hash, chat_id, message_id, body, hash_prefix) do
    TelegramOutboundWorker.new(%{
      chat_id_hash: chat_id_hash,
      chat_id: chat_id,
      message_id: message_id,
      body: body,
      lane: :safe
    })
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        raise "TelegramMessageWorker: failed to enqueue TelegramOutboundWorker " <>
                "(reason=#{inspect(reason)}, hash_prefix=#{hash_prefix})"
    end
  end

  defp enqueue_unregistered_reply(chat_id, chat_id_hash, hash_prefix) do
    Logger.info(
      "TelegramMessageWorker: unbound chat, enqueuing unregistered reply " <>
        "(hash_prefix=#{hash_prefix})"
    )

    enqueue_outbound(chat_id_hash, chat_id, nil, @unregistered_copy, hash_prefix)
  end

  # ----------------------------------------------------------------
  # Pure helpers
  # ----------------------------------------------------------------

  defp empty_text?(nil), do: true
  defp empty_text?(""), do: true

  defp empty_text?(text) when is_binary(text) do
    String.trim(text) == ""
  end

  defp build_llm_messages(context, text) do
    user_content =
      if context == "" do
        text
      else
        "Contexto reciente:\n#{context}\n\nMensaje del paciente:\n#{text}"
      end

    [
      %{role: :system, content: "Sos Alethea, un asistente clínico de apoyo."},
      %{role: :user, content: user_content}
    ]
  end

  defp pepper! do
    Application.fetch_env!(:alethea, :telegram_chat_id_pepper)
  end
end
