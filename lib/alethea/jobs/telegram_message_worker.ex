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
    7. Route the reply through `Alethea.AI.PhiWorker.process/1` (PII-sanitized, emotion-enriched), then anchor an `ai_diagnosis` to the inbound message before enqueueing the outbound (REQ-C5-llm-reply-on-safe).
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

  alias Alethea.{Accounts, Clinical, Repo}
  alias Alethea.Alerts.CrisisMonitor
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Telegram.{ChatIdHash, LogRedactor}
  alias Alethea.Jobs.TelegramOutboundWorker
  alias AletheaJobs.EmotionAnalysisWorker

  @unregistered_copy "Hola. No reconozco este chat en nuestro sistema clínico. Si eres un paciente, por favor contacta a tu terapeuta para que te registre."

  # Reads the PhiWorker port from Application env at call-time.
  # Mirrors `AletheaJobs.ProcessMessageWorker` (the WhatsApp pipeline)
  # so the Telegram safe path and the WhatsApp pipeline converge on
  # the same PII-sanitizing, emotion-enriching chain. Production uses
  # `Alethea.AI.PhiWorker`; tests bind the port to the Mox
  # `Alethea.AI.PhiWorkerMock`.
  defp phi_worker, do: Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{message: message} = args
    %{"chat" => %{"id" => chat_id}, "message_id" => telegram_message_id, "text" => text} = message

    chat_id_hash = ChatIdHash.hash(chat_id, pepper!())
    hash_prefix = LogRedactor.prefix(chat_id_hash)

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
      # The crisis branch reads `legacy_patient.professional.crisis_message`,
      # so we preload the `:professional` association here (the safe
      # path doesn't need it but the cost is one extra column and the
      # branch is mutually exclusive with the safe path).
      {:ok, legacy_patient} = FoundationAccounts.legacy_patient(foundation_patient)
      legacy_patient = Accounts.get_patient_with_professional(legacy_patient.id)

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

        {:crisis, level, triggers} ->
          handle_crisis_path(
            foundation_patient,
            legacy_patient,
            chat_id,
            chat_id_hash,
            hash_prefix,
            inbound,
            level,
            triggers
          )
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

    case phi_worker().process(%{
           message_id: inbound.id,
           raw_content: text,
           patient_context: context
         }) do
      {:ok, %{response: reply} = chain_result}
      when is_binary(reply) and reply != "" ->
        persist_and_enqueue_outbound(
          foundation_patient,
          chat_id,
          chat_id_hash,
          hash_prefix,
          chain_result,
          inbound.id
        )

      {:ok, %{response: _empty}} ->
        raise "TelegramMessageWorker: PhiWorker returned empty response " <>
                "(hash_prefix=#{hash_prefix})"

      {:error, reason} ->
        raise "TelegramMessageWorker: PhiWorker error: #{inspect(reason)} " <>
                "(hash_prefix=#{hash_prefix})"
    end
  end

  defp persist_and_enqueue_outbound(
         foundation_patient,
         chat_id,
         chat_id_hash,
         hash_prefix,
         chain_result,
         inbound_message_id
       ) do
    reply = chain_result.response

    # Both inserts run inside a single Repo.transaction (Round 2
    # SEVERE fix — atomicity): the outbound Message row and the
    # ai_diagnosis anchor either both commit or neither does. Without
    # this, a diagnosis-save failure after the outbound insert already
    # committed would leave a fabricated "elicited" Message row
    # persisted (a reply the patient never actually received, because
    # the job raises and the caller never reaches `enqueue_outbound/6`).
    # `Repo.rollback/1` unwinds the outbound insert too, so a retry
    # starts from a clean slate — no orphaned clinical record.
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, outbound} <-
               Clinical.save_telegram_message(
                 foundation_patient,
                 reply,
                 "outbound",
                 "elicited",
                 nil
               ),
             {:ok, _diagnosis} <-
               Clinical.save_ai_diagnosis(inbound_message_id, chain_result) do
          outbound
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, outbound} ->
        enqueue_outbound(chat_id_hash, chat_id, outbound.id, reply, hash_prefix,
          # Round 1 (WARNING-5): foundation UUID, not legacy integer.
          patient_id: foundation_patient.id
        )

        :ok

      {:error, reason} ->
        # PHI hygiene (Round 2 SEVERE fix): never embed the full
        # changeset in the raised message. `inspect(%Ecto.Changeset{})`
        # includes `changes` — which, for the diagnosis changeset,
        # carries the plaintext `ai_response`. Report only the failed
        # field keys (or the raw reason for non-changeset errors).
        raise "TelegramMessageWorker: failed to persist AI reply/diagnosis " <>
                "(reason=#{safe_reason(reason)}, hash_prefix=#{hash_prefix})"
    end
  end

  # Renders a persistence failure reason WITHOUT leaking changeset
  # `changes` (which may hold plaintext clinical content, e.g.
  # `ai_response`). For an `Ecto.Changeset`, only the field keys that
  # failed validation are surfaced; any other reason is inspected
  # as-is (non-changeset reasons carry no PHI).
  defp safe_reason(%Ecto.Changeset{errors: errors}) do
    errors |> Keyword.keys() |> Enum.uniq() |> inspect()
  end

  defp safe_reason(reason), do: inspect(reason)

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

  defp enqueue_outbound(chat_id_hash, chat_id, message_id, body, hash_prefix, opts \\ []) do
    lane = Keyword.get(opts, :lane, :safe)
    # `patient_id` is the foundation Patient's id (UUID). It flows to
    # the outbound worker so a crisis dead-letter broadcast can carry
    # the operator-visible identifier (REQ-C7-crisis-priority-lane +
    # TASK-3b-4 crisis clinical-incident signal). Nil-safe: the
    # unregistered-chat reply (no patient) passes nil.
    patient_id = Keyword.get(opts, :patient_id)
    # Crisis lane is the dedicated `telegram_outbound_crisis` Oban
    # queue (REQ-C7-crisis-priority-lane). The safe lane stays on
    # `telegram_outbound`. The Oban queue name is the Oban worker's
    # `queue:` option overridden at enqueue-time; the
    # `TelegramOutboundWorker` module is registered against both
    # queues in `config/config.exs`.
    queue = if lane == :crisis, do: :telegram_outbound_crisis, else: :telegram_outbound

    # Job-level priority (REQ-C7-crisis-priority-lane). In Oban,
    # lower numbers = higher priority (0 is highest). The crisis lane
    # uses `0` to outrank the safe lane's default `9` (set at the
    # worker level via `use Oban.Worker`). Until Oban Pro lands
    # (queue-level priority weighting), the priority lane is enforced
    # here, NOT in `config/config.exs`. See `config/config.exs` for
    # the full rationale.
    priority = if lane == :crisis, do: 0, else: 9

    new_args = %{
      chat_id_hash: chat_id_hash,
      chat_id: chat_id,
      message_id: message_id,
      body: body,
      lane: lane,
      priority: priority,
      patient_id: patient_id
    }

    new_args
    |> TelegramOutboundWorker.new(queue: queue, priority: priority)
    |> out_enqueue().insert()
    |> case do
      {:ok, _job} ->
        :ok

      # Crisis lane queue-full escalation (REQ-C7-crisis-queue-full-escalation).
      # The escalation path is exercised only by Mox-stubbed tests today
      # because Oban 2.x open-source does NOT return `{:error, :queue_full}`
      # from `Oban.insert/1` — queue saturation in `Oban.Engines.Basic` is
      # enforced at FETCH time (when `map_size(running) >= limit`),
      # not insert time. The catch clause below is kept as a defensive
      # guard for: (a) future Oban engines / versions that DO emit
      # `:queue_full`; (b) the Mox-stubbed crisis-lane escalation test.
      # A real production queue-full detector is a follow-up issue
      # (pre-insert `Oban.check_queue/2` or telemetry-driven escalation).
      # See `openspec/sdd/telegram-paciente-foundation/apply-progress.md`
      # for the gap documentation.
      {:error, :queue_full} when lane == :crisis ->
        escalate_to_perform_now(new_args, hash_prefix)

      {:error, reason} ->
        raise "TelegramMessageWorker: failed to enqueue TelegramOutboundWorker " <>
                "(reason=#{inspect(reason)}, hash_prefix=#{hash_prefix}, lane=#{lane})"
    end
  end

  # Reads the outbound enqueue adapter from Application env at call-time.
  # Production uses the real `Alethea.Telegram.OutboundEnqueue` (which
  # delegates to `Oban.insert/1`); tests can override via Mox to stub
  # insert failures (e.g., queue_full for the crisis-lane escalation test).
  defp out_enqueue do
    Application.get_env(
      :alethea,
      :telegram_outbound_enqueue,
      Alethea.Telegram.OutboundEnqueue
    )
  end

  @doc """
  Escalation path invoked when the crisis Oban queue is at capacity
  (REQ-C7-crisis-queue-full-escalation).

  Public so tests can drive the escalation directly (the `enqueue_outbound/6`
  catch path is also exercised via Mox-stubbed `Oban.insert/1`).

  Steps:
    1. Log a `Logger.warning` documenting the escalation (the
       `hash_prefix` is the only PHI surface logged).
    2. Invoke `TelegramOutboundWorker.perform_now/1` inline. The
       Pacer is acquired (the rate-limit is preserved) and the send
       runs synchronously. If the inline send fails, perform_now
       dead-letters immediately (no queue to retry through).
    3. Broadcast `:crisis_queue_full` on `"ops:alerts"` PubSub with
       `chat_id_hash`, `body_length`, `delivered`, `at`. The
       `delivered` boolean reflects the post-perform_now outcome so
       operator dashboards don't react to a "queue full" event and
       try to replay a send that ALREADY succeeded. The payload
       intentionally omits `text: body` — operators don't need the
       outbound body in the alert (it's the psychologist's
       preconfigured `crisis_message`, not the patient's words) and
       keeping it off the PubSub bus follows the project's R-1 PHI
       hygiene rule.

  Returns `:ok` always — escalation is the success path; per-call
  failures are surfaced via dead-letter + ops broadcast, not by
  raising from this function.
  """
  @spec escalate_to_perform_now(map(), String.t()) :: :ok
  def escalate_to_perform_now(args, hash_prefix) do
    chat_id_hash = Map.fetch!(args, :chat_id_hash)
    body = Map.fetch!(args, :body)

    Logger.warning(
      "TelegramMessageWorker: crisis queue full, escalating to perform_now " <>
        "(hash_prefix=#{hash_prefix})"
    )

    # The in-process `args` map uses atom keys (the worker's own
    # convention for the pre-insert step). `TelegramOutboundWorker.perform_now/1`
    # expects string keys (the Oban re-hydrated contract). Convert
    # atomically before delegating so the callee reads the same
    # shape it would read from `oban_jobs.args`.
    string_args = Map.new(args, fn {k, v} -> {to_string(k), v} end)

    # Run the inline send FIRST, then broadcast the outcome. The
    # broadcast must reflect the post-perform_now result (`delivered: true
    # | false`) so operator dashboards don't react to a "queue full"
    # event and try to replay a send that ALREADY succeeded (which
    # would double-send the crisis message to the patient). The
    # payload intentionally omits `text: body` — operators don't need
    # the outbound body in the alert (it's the psychologist's
    # preconfigured `crisis_message`, not the patient's words) and
    # keeping it off the PubSub bus follows the project's R-1 PHI
    # hygiene rule (the same rule that drives `LogRedactor` for
    # logs).
    delivered =
      case TelegramOutboundWorker.perform_now(string_args) do
        :ok -> true
        {:error, _reason} -> false
      end

    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      "ops:alerts",
      {:crisis_queue_full,
       %{
         chat_id_hash: chat_id_hash,
         body_length: byte_size(body),
         delivered: delivered,
         at: DateTime.utc_now()
       }}
    )

    :ok
  end

  defp enqueue_unregistered_reply(chat_id, chat_id_hash, hash_prefix) do
    Logger.info(
      "TelegramMessageWorker: unbound chat, enqueuing unregistered reply " <>
        "(hash_prefix=#{hash_prefix})"
    )

    enqueue_outbound(chat_id_hash, chat_id, nil, @unregistered_copy, hash_prefix)
  end

  # ----------------------------------------------------------------
  # Crisis branch (REQ-C5-crisis-bypasses-llm, REQ-C5-crisis-broadcasts-alert,
  #                 REQ-C5-persist-outbound-reply)
  # ----------------------------------------------------------------

  # The crisis branch (REQ-C5-crisis-bypasses-llm): on a `:crisis`
  # classification the worker MUST NOT call the LLM. Instead it:
  #
  #   1. Marks the patient `urgent_intervention: true` on the legacy
  #      Patient row (the foundation row is the identity surface; the
  #      clinical-state flag lives on the legacy row).
  #   2. Saves a `crisis-bypass` ai_diagnosis row for audit (the
  #      `model_version: "crisis-bypass"` discriminator is the
  #      clinical/operational signal that distinguishes a bypass
  #      from a normal elicited reply).
  #   3. Broadcasts `:crisis_detected` on `"psychologist:alerts"`
  #      PubSub with `patient_id`, `chat_id_hash`, `level`, and
  #      `triggers` so the dashboard / LiveView can react.
  #   4. Persists the outbound Message with
  #      `behavior_type: "crisis_bypass"` (REQ-C5-persist-outbound-reply
  #      "crisis_bypass source") so the clinical record reflects what
  #      the patient is about to see, even if the network send later
  #      fails.
  #   5. Enqueues a `TelegramOutboundWorker` job on the
  #      `:telegram_outbound_crisis` priority queue (REQ-C7-crisis-priority-lane)
  #      with `lane: :crisis`. The crisis lane is independent of
  #      the safe lane's saturation (TASK-3b-3 escalates to
  #      `perform_now/1` if the lane is full).
  defp handle_crisis_path(
         foundation_patient,
         legacy_patient,
         chat_id,
         chat_id_hash,
         hash_prefix,
         inbound,
         level,
         triggers
       ) do
    crisis_text = crisis_reply_text(legacy_patient)

    # 1. Mark urgent_intervention on the legacy Patient.
    {:ok, _updated_patient} =
      Alethea.Accounts.update_patient(legacy_patient, %{urgent_intervention: true})

    # 2. Save a crisis-bypass ai_diagnosis row for audit.
    {:ok, _diagnosis} =
      Clinical.save_ai_diagnosis(inbound.id, %{
        response: crisis_text,
        model_version: "crisis-bypass",
        extracted_emotions: %{crisis: true, level: level, triggers: triggers}
      })

    # 3. Broadcast on psychologist:alerts.
    # Round 1 (WARNING-5): the operator-visible patient_id is the
    # foundation Patient's UUID (the foundation row is the identity
    # surface per the foundation/legacy split; the legacy `patients`
    # table is the clinical-state surface — `urgent_intervention`
    # lives there). The PubSub broadcast and the dead-letter row
    # MUST use the foundation UUID so the FK resolves and operator
    # dashboards correlate to the foundation patient record.
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      "psychologist:alerts",
      {:crisis_detected,
       %{
         patient_id: foundation_patient.id,
         chat_id_hash: chat_id_hash,
         level: level,
         triggers: triggers,
         at: DateTime.utc_now()
       }}
    )

    # 4. Persist the outbound Message with `behavior_type: "crisis_bypass"`.
    {:ok, outbound} =
      Clinical.save_telegram_message(
        foundation_patient,
        crisis_text,
        "outbound",
        "crisis_bypass",
        nil
      )

    # 5. Enqueue on the :telegram_outbound_crisis lane.
    # Round 1 (WARNING-5): same fix as the broadcast — pass
    # `foundation_patient.id` (the foundation UUID), not
    # `legacy_patient.id` (the legacy integer). The FK on
    # `foundation_outbound_dead_letters.patient_id` requires the
    # foundation UUID; previously the worker passed the legacy
    # integer and the FK silently didn't exist.
    enqueue_outbound(chat_id_hash, chat_id, outbound.id, crisis_text, hash_prefix,
      lane: :crisis,
      patient_id: foundation_patient.id
    )

    Logger.warning(
      "TelegramMessageWorker: crisis branch (hash_prefix=#{hash_prefix}, " <>
        "level=#{level}, triggers=#{length(triggers)})"
    )

    :ok
  end

  # Resolve the crisis-bypass reply text. The psychologist preconfigures
  # a per-professional `crisis_message` (the patient-facing reply the
  # system sends when a `:crisis` classification lands). If unset, fall
  # back to a system default — same fallback the WhatsApp pipeline uses
  # (`AletheaJobs.ProcessMessageWorker` moduledoc).
  defp crisis_reply_text(legacy_patient) do
    legacy_patient.professional.crisis_message ||
      Application.get_env(
        :alethea,
        :crisis_support_message,
        default_crisis_support_message()
      )
  end

  defp default_crisis_support_message do
    "Entiendo que estás pasando por algo muy difícil. Lo que sientes importa."
  end

  # ----------------------------------------------------------------
  # Pure helpers
  # ----------------------------------------------------------------

  defp empty_text?(nil), do: true
  defp empty_text?(""), do: true

  defp empty_text?(text) when is_binary(text) do
    String.trim(text) == ""
  end

  defp pepper! do
    Application.fetch_env!(:alethea, :telegram_chat_id_pepper)
  end
end
