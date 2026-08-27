defmodule AletheaJobs.SessionTimeoutWorker do
  @moduledoc """
  Channel-neutral session-timeout Oban worker (PR-1 of #86).

  Closes the session after the inactivity window, runs the shared
  summary/trends pipeline, and dispatches the goodbye through the
  channel recorded in the job args (currently `"telegram"`; the
  legacy `"whatsapp"` path was retired in #87).

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
    * **Actual safeguards** for `oban_jobs.args` access (honest
      inventory — see R2 tightening):
        - PostgreSQL row-level privileges (operational role
          limited to job-management views). Operationally managed
          outside this repo; if a deployment does NOT enforce them,
          the only remaining guard is TLS.
        - TLS-encrypted connections to Postgres (operationally
          managed; if disabled, `chat_id` traverses the network in
          plaintext).
        - Per-call `AletheaJobs.SafeReason.for_log/1` at error
          sites (this worker + `TelegramMessageWorker`). Renders
          `Ecto.Changeset.errors` keys only — the `changes` map
          (which embeds `summary_text` / `ai_response` / `body`)
          never appears in a log line. See the
          `AletheaJobs.SafeReason` moduledoc for the rationale.
        - Per-call `Alethea.Telegram.LogRedactor.prefix/1` /
          `redact/1` scrubs the 64-char lowercase-hex
          `chat_id_hash` shape out of arbitrary log strings (used
          in `TelegramMessageWorker`, NOT this worker — this
          worker uses `SafeReason.for_log/1` for changesets and
          `Logger.error` only with the bare `session.id`
          correlation token).
    * **Known gaps** (open follow-ups — NOT promises of current
      protection):
        - NO `Oban.Plugins.Pruner` is configured in `config/*.exs`
          (`config/config.exs:91-96` only enables
          `Oban.Plugins.Cron`). Completed / discarded `oban_jobs`
          rows survive forever in the DB. Removing or
          anonymizing `chat_id` after a window is a follow-up
          issue — until that lands, `chat_id` and `chat_id_hash`
          accumulate in `oban_jobs.args` for the lifetime of the
          table. (A previous version of this moduledoc claimed
          Oban's prune settings were configured; that claim was
          aspirational, not actual, and has been removed in R2.)
        - NO global Logger redaction backend is configured —
          `SafeReason.for_log/1` is per-call. If a future error
          site forgets to apply it, a Changeset's `changes` would
          land in the log undredacted. A follow-up could
          centralize this as either a real Logger backend or a
          wrapper helper.
    * No encrypted column is added (consistent with the existing
      pattern across the codebase). Removing `chat_id` from args
      would force a DB lookup by `chat_id_hash` at goodbye
      dispatch time, adding latency and a new failure mode (DB
      unavailable) at exactly the wrong moment. The chosen
      design keeps `chat_id` in args; this is the same posture as
      the pre-existing `TelegramOutboundWorker` and is not a
      regression introduced by #86.
  """

  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3,
    # `period: :infinity` keeps args-based uniqueness active for the
    # session's lifetime — see @moduledoc "Uniqueness policy".
    unique: [fields: [:args], period: :infinity]

  alias Alethea.{Accounts, AI, Clinical}
  alias Alethea.AI.Sanitizer
  alias Alethea.Clinical.{EmotionAnalysis, Session, SessionManager}
  alias AletheaJobs.SafeReason

  require Logger

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

  # Legacy WhatsApp timeout job scheduled before the #87 retirement. The
  # close/summary/trends pipeline is channel-independent, so we still close
  # the session and persist its summary — only the retired WhatsApp goodbye
  # send is skipped (routed to `send_goodbye/2`'s unknown-channel backstop,
  # which no-ops the send). A job matching neither the Telegram clause above
  # nor this legacy `"phone"` shape raises FunctionClauseError (fails loud +
  # Oban-visible) rather than being silently swallowed.
  def perform(%Oban.Job{
        args: %{
          "session_id" => session_id,
          "patient_id" => patient_id,
          "phone" => _phone
        }
      }) do
    session = Alethea.Repo.get!(Session, session_id)

    if session.status == "closed" do
      :ok
    else
      run_close_flow(session, patient_id, channel: "retired_whatsapp")
    end
  end

  defp run_close_flow(session, patient_id, opts) do
    patient = Accounts.get_patient!(patient_id)

    with {:ok, closed_session} <- SessionManager.close_session(session),
         messages <- Clinical.list_session_messages(closed_session.id),
         {:ok, texts} <- decrypt_messages(patient, messages),
         sanitized_texts = Enum.map(texts, &Sanitizer.sanitize/1),
         {:ok, emotion_scores} <- AI.emotion_analyzer().analyze_batch(sanitized_texts),
         {:ok, _emotion_data} <- EmotionAnalysis.canonical_scores(emotion_scores),
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
        # PHI-safe error rendering (R2 #86 PR-1 fix). Bare
        # `inspect(reason)` would embed `Ecto.Changeset.changes`
        # — which carries `summary_text` (AI-generated clinical
        # summary) + `patient_id` when `Clinical.save_summary/1`
        # fails validation. `SafeReason.for_log/1` only surfaces
        # the failed-validation field keys for changesets; for
        # non-changeset reasons it falls back to `inspect/1` (which
        # is the desired behaviour — non-changeset reasons carry
        # no PHI by shape). See `AletheaJobs.SafeReason` moduledoc.
        Logger.error(
          "SessionTimeoutWorker failed for session #{session.id}: #{SafeReason.for_log(reason)}"
        )

        {:error, reason}
    end
  end

  # Channel switch on the goodbye send (PR-1 #86). The summary /
  # trends pipeline is channel-independent (it was always
  # channel-independent — only the final send was WhatsApp-coupled).
  # The goodbye body text is identical across channels; the dispatch
  # target differs:
  #
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
