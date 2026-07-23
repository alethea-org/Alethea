defmodule AletheaJobs.SessionTimeoutWorker do
  @moduledoc """
  Channel-neutral session-timeout Oban worker (PR-1 of #86).

  Closes the session after the inactivity window, runs the shared
  summary/trends pipeline, and dispatches the goodbye through the
  channel recorded in the job args (`"whatsapp"` or `"telegram"`).

  ## Uniqueness policy (Round 1 fix — verify-flagged CRITICAL)

  The worker's `unique: [fields: [:args], period: :infinity]` policy
  guarantees a single scheduled timeout row per open-session tuple
  for the lifetime of the args combination. An earlier
  `period: 40 * 60` (40-minute) window expired the uniqueness check
  against `inserted_at` — once that 40-minute horizon passed, a
  renewal `Oban.insert!(replace: [:scheduled_at])` could no longer
  find a matching unique row to replace and inserted a second job,
  producing duplicate timeouts on long Telegram conversations.
  `:infinity` holds uniqueness for the session's lifetime; the row
  is replaced (not appended) on each renewal as long as the session
  is still open, and the prior row is removed by Oban when the
  replacement commits.

  ## Renewal companion fix — `replace:` option format

  The renewal call site (`telegram_message_worker.ex:341-354`) had
  `Oban.insert!(replace: [:scheduled_at])` — a plain list, which
  Oban's `resolve_conflict/4` ignores (it calls `Keyword.get/3`
  keyed by job state, so a non-keyword list returns `[]` and the
  `scheduled_at` is never actually updated on conflict). This was a
  silent no-op that the pre-fix renewal test (count-only) did not
  catch. Fixed to `replace: [scheduled: [:scheduled_at]]` (the
  Oban 2.x state-keyed keyword form). The Round 1 strengthened
  test asserts `scheduled_at` is strictly later after renewal —
  exercising the now-working update path.

  ## PHI at rest — `chat_id` in `oban_jobs.args` (Round 1 — WARNING #1)

  The raw Telegram `chat_id` IS persisted at rest in `oban_jobs.args`
  (JSONB column), alongside the HMAC `chat_id_hash`. This was
  already the case for `TelegramOutboundWorker` (#84, pre-existing)
  and is now also true here in PR-1 #86 for the goodbye dispatch
  path. The codebase comment that previously said "chat_id is never
  persisted at rest" was inaccurate and has been corrected.

  Threat model acknowledgement (bounded PHI-at-rest surface):

    * `chat_id` (plaintext Telegram identifier) lives ONLY in
      `oban_jobs.args`. It does NOT appear in any clinical table
      (no `messages.encrypted_content`, no `sessions`, no
      `foundation_patients`, etc.).
    * `chat_id_hash` (HMAC-SHA256 with the configured pepper) is
      the canonical lookup key used by the Pacer rate-limiter and
      the dead-letter audit table — `chat_id` itself is only used
      at Telegram dispatch time.
    * Safeguards for `oban_jobs.args` access: PostgreSQL row-level
      privileges (operational role limited to job-management
      views), TLS-encrypted connections, application-level
      `LogRedactor` on error serialization, and Oban's
      `prune`/retention settings purge completed/failed rows on
      schedule. No encrypted column is added (consistent with the
      existing pattern across the codebase).
    * Removing `chat_id` from args would force a DB lookup by
      `chat_id_hash` at goodbye dispatch time, adding latency and
      a new failure mode (DB unavailable) at exactly the wrong
      moment. The chosen design keeps `chat_id` in args; this is
      the same posture as the pre-existing `TelegramOutboundWorker`
      and is not a regression introduced by #86.
  """

  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3,
    # `period: :infinity` keeps args-based uniqueness active for the
    # session's lifetime — see @moduledoc "Uniqueness policy".
    unique: [fields: [:args], period: :infinity]

  alias Alethea.{Accounts, Clinical, AI.Sanitizer}
  alias Alethea.Clinical.{Session, SessionManager}

  require Logger

  defp whatsapp_client,
    do: Application.get_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)

  defp roberta_worker,
    do: Application.get_env(:alethea, :roberta_worker, Alethea.AI.RoBERTaWorker)

  defp session_summary_chain,
    do:
      Application.get_env(:alethea, :session_summary_chain, Alethea.AI.Chains.SessionSummaryChain)

  @goodbye_message """
  Tu sesión de hoy ha concluido. Tu terapeuta podrá revisar el resumen en el próximo encuentro.
  Hasta pronto.
  """

  # Telegram goodbye dispatch target (PR-1 #86). Both the raw
  # `chat_id` and the HMAC `chat_id_hash` ride in Oban job args at
  # enqueue-time (the only place the raw chat_id is available in
  # process). NOTE: the raw `chat_id` IS persisted at rest in
  # `oban_jobs.args` (JSONB) for the duration of the job — see the
  # module @moduledoc "PHI at rest — chat_id in oban_jobs.args" for
  # the threat-model acknowledgement and the relevant safeguards.
  # The goodbye is enqueued on the safe lane with `patient_id: nil`
  # — goodbyes are nil-safe per design (see design.md).
  alias Alethea.Jobs.TelegramOutboundWorker

  @impl Oban.Worker
  # Telegram-channel args (PR-1 #86). Channel dispatch via Oban args
  # (no migration, no Session schema column) — see exploration.md's
  # "Channel-dispatch mechanism" decision.
  def perform(%Oban.Job{
        args: %{
          "session_id" => session_id,
          "patient_id" => patient_id,
          "channel" => "telegram",
          "chat_id" => chat_id,
          "chat_id_hash" => chat_id_hash
        }
      }) do
    session = Alethea.Repo.get!(Session, session_id)

    if session.status == "closed" do
      :ok
    else
      run_close_flow(session, patient_id,
        channel: "telegram",
        chat_id: chat_id,
        chat_id_hash: chat_id_hash
      )
    end
  end

  # Legacy WhatsApp args shape (unchanged, preserved by the
  # `process_message_worker.ex` pipeline). Absent `channel` + present
  # `phone` defaults to `"whatsapp"` (Req: WhatsApp Backward
  # Compatibility — the 2 pre-existing tests stay green unmodified).
  def perform(%Oban.Job{
        args:
          %{
            "session_id" => session_id,
            "patient_id" => patient_id,
            "phone" => phone
          } = args
      }) do
    channel = Map.get(args, "channel", "whatsapp")
    session = Alethea.Repo.get!(Session, session_id)

    if session.status == "closed" do
      :ok
    else
      run_close_flow(session, patient_id, channel: channel, phone: phone)
    end
  end

  defp run_close_flow(session, patient_id, opts) do
    patient = Accounts.get_patient!(patient_id)

    with {:ok, closed_session} <- SessionManager.close_session(session),
         messages <- Clinical.list_session_messages(closed_session.id),
         {:ok, texts} <- decrypt_messages(patient, messages),
         sanitized_texts = Enum.map(texts, &Sanitizer.sanitize/1),
         emotion_scores <- roberta_worker().analyze_batch(sanitized_texts),
         :ok <- Clinical.save_trends(patient, emotion_scores, closed_session),
         {:ok, summary_text} <- session_summary_chain().run(sanitized_texts, emotion_scores),
         {:ok, _summary} <-
           Clinical.save_summary(%{
             period_start: closed_session.started_at,
             period_end: closed_session.closed_at,
             summary_text: summary_text,
             status_level: extract_status_level(summary_text),
             type: "session",
             patient_id: patient.id
           }) do
      send_goodbye(opts, @goodbye_message)
      :ok
    else
      {:error, reason} ->
        Logger.error("SessionTimeoutWorker failed for session #{session.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Channel switch on the goodbye send (PR-1 #86). The summary /
  # trends pipeline is channel-independent (it was always
  # channel-independent — only the final send was WhatsApp-coupled).
  # The goodbye body text is identical across channels; the dispatch
  # target differs:
  #
  #   * `"whatsapp"` → existing inline send via the WhatsApp client
  #     (unchanged behavior — the 2 pre-existing tests stay green
  #     unmodified).
  #   * `"telegram"` → enqueue a `TelegramOutboundWorker` goodbye job
  #     on the safe lane with `patient_id: nil` (goodbyes are
  #     nil-safe per design). The raw `chat_id` + `chat_id_hash`
  #     were carried in the SessionTimeoutWorker job args from the
  #     enqueue site (see `telegram_message_worker.ex:341-354`) —
  #     they are NOT recoverable from any persisted Session column,
  #     but they ARE persisted at rest in `oban_jobs.args` for the
  #     lifetime of the scheduled timeout job (see the worker
  #     @moduledoc "PHI at rest — chat_id in oban_jobs.args").
  defp send_goodbye(opts, body) when is_list(opts) do
    case Keyword.fetch!(opts, :channel) do
      "telegram" ->
        chat_id = Keyword.fetch!(opts, :chat_id)
        chat_id_hash = Keyword.fetch!(opts, :chat_id_hash)

        TelegramOutboundWorker.new(%{
          chat_id: chat_id,
          chat_id_hash: chat_id_hash,
          body: body,
          patient_id: nil
        })
        |> Oban.insert!()

        :ok

      "whatsapp" ->
        phone = Keyword.fetch!(opts, :phone)
        whatsapp_client().send_message(phone, body)

      other ->
        # Backstop: unknown channel (future addition). The session is
        # already closed + summary/trends persisted — a missing goodbye
        # is the gentlest possible failure mode. Logged, no raise.
        Logger.warning(
          "SessionTimeoutWorker: unknown channel for goodbye send (channel=#{inspect(other)})"
        )

        :ok
    end
  end

  defp decrypt_messages(patient, messages) do
    case Clinical.patient_dek(patient) do
      {:ok, dek} ->
        texts =
          Enum.map(messages, fn msg ->
            {:ok, text} = Clinical.decrypt_message_content(msg, dek)
            text
          end)

        {:ok, texts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_status_level(text) do
    cond do
      String.contains?(text, "Intervención") -> "Intervención Requerida"
      String.contains?(text, "Alerta") -> "Alerta"
      true -> "Estable"
    end
  end
end
