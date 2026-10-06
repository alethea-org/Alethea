defmodule Alethea.Jobs.TelegramOutboundWorker do
  @moduledoc """
  Oban worker that ships an outbound Telegram reply to the patient
  (C-7 outbound + dead-letter; PR #3a / TASK-3a-2).

  ## Lifecycle

    1. Acquire a Pacer token for the chat (`Pacer.acquire/1`). This
       blocks until both the per-chat bucket (1 msg/s) and the
       global bucket (30 msg/s) have tokens.
    2. Call `Alethea.Telegram.Client.send_message(chat_id, body)`.
       The adapter is selected at compile-time from
       `Application.get_env(:alethea, :telegram_client)`.
    3. On `{:ok, _}` → return `:ok`.
    4. On `{:error, reason}`:
       - If `attempt >= @max_attempts` (5): write a dead-letter row to
         `foundation_outbound_dead_letters`, broadcast
         `{:outbound_dead_letter, %{…}}` on `"ops:alerts"`, and
         return `:ok` so Oban does NOT schedule a 6th retry.
       - Else: reschedule via `Oban.insert/2` with a
         `scheduled_at` computed from the backoff + jitter rules.

  ## Backoff (REQ-C7-429-retry-with-jitter)

  The cap-and-jitter rules:
    - 429 with `Retry-After: N` → `N` seconds ± 25% jitter.
    - 5xx / network / unknown → `base_backoff_ms * 2^(attempt - 1)`
      capped at `max_backoff_ms`, ± 25% jitter.
    - Production defaults: `base_backoff_ms = 1_000`,
      `max_backoff_ms = 300_000` (5 min). Tests override.

  ## Delivery outcomes for persisted replies (issue #390)

  When the args carry the `message_id` of a persisted reply, the reply
  row holds the delivery state and this worker is what moves it
  (`Alethea.Clinical.claim_telegram_delivery/1`,
  `record_telegram_delivery/2`). Jobs without a tracked row (unregistered
  chat, onboarding, reminders, goodbyes) keep the lifecycle above
  unchanged.

  Journaling lane — at most one patient-visible send per reply:

    * The execution **claims** the row before sending. Only one execution
      can hold the claim; any other finds the reply sent (no-op) or in
      flight. In flight without a recorded outcome means an execution may
      have reached Telegram and died, so it is recorded as `ambiguous`
      and NOT sent.
    * `{:ok, id}` → `sent`, Telegram's id stored. Never sent again.
    * An error that proves the message was not delivered
      (`Client.not_delivered?/1`: 429, explicit rejection, connection
      never established) → the claim is released and the job reschedules;
      on exhaustion the reply is `failed` and dead-lettered.
    * Any other error (timeout after the request was sent, 5xx, unknown)
      → `ambiguous`: no reschedule, no dead-letter, no resend. At-most-one
      is chosen over delivery certainty, so an ambiguous journaling reply
      may never arrive.

  Crisis lane — delivery policy unchanged: no claim, every error
  (ambiguous ones included) is retried up to the budget and then
  dead-lettered. The row only records `sent` on acknowledgement (an
  acknowledged crisis reply is not sent again by a repeated job) and
  `failed` on dead-letter.

  ## Why `max_attempts: 1` on the worker

  Oban's built-in retry would stack on top of the worker's own
  exponential backoff (`Oban.retry` uses its own `backoff` config,
  not the worker's). `max_attempts: 1` ensures Oban does NOT
  auto-retry on top of the worker's manual `Oban.insert/2`
  reschedule. The retry counter (`_attempt`) is passed in the args
  and incremented by the worker itself.

  ## Why the chat_id is in the args (PHI surface)

  The args carry BOTH `chat_id_hash` (for the Pacer key) AND
  `chat_id` (the plaintext Telegram identifier, required by
  `Client.send_message/2`). The chat_id is the Telegram API's
  addressing primitive; without it the send cannot happen. The
  hash is the rate-limit key (PHI hygiene: logs carry the prefix
  only). Both surfaces are intentional and documented.

  ## Out of scope (PR #3b)

  - Crisis-bypass `perform_now/1` escalation when the crisis queue
    reports `:queue_full` (REQ-C7-crisis-queue-full-escalation).
  - The crisis lane `:telegram_outbound_crisis` queue is registered
    (PR #2) but the worker body does not route to it yet — the
    `TelegramMessageWorker` enqueues on `:telegram_outbound` only.
  """

  use Oban.Worker, queue: :telegram_outbound, max_attempts: 1

  require Logger

  alias Alethea.Clinical
  alias Alethea.Telegram.{Pacer, Client, LogRedactor}
  alias Alethea.Foundation.Accounts.OutboundDeadLetter
  alias Alethea.Repo

  @max_attempts 5
  @base_backoff_ms 1_000
  @max_backoff_ms 300_000
  @jitter_ratio 0.25

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: _oban_attempt, priority: oban_priority}) do
    chat_id = Map.fetch!(args, "chat_id")
    chat_id_hash = Map.fetch!(args, "chat_id_hash")
    body = Map.fetch!(args, "body")
    attempt = Map.get(args, "_attempt", 1)
    # The `lane` (`:safe | :crisis`) and `priority` fields are
    # preserved across retries so a crisis retry stays on the
    # `:telegram_outbound_crisis` lane AND keeps its Oban priority
    # (REQ-C7-crisis-priority-lane — the crisis lane cannot be starved
    # by a full `:telegram_outbound` queue).
    lane = Map.get(args, "lane", :safe)
    # Prefer the in-args `priority` (the Oban job's `priority:` is the
    # authoritative value when the worker re-inserts via `new/2`).
    priority = Map.get(args, "priority", oban_priority)
    # `patient_id` is the foundation Patient's id (UUID). It is
    # forwarded from `TelegramMessageWorker` so the crisis dead-letter
    # PubSub broadcast can carry the operator-visible identifier
    # (REQ-C7-crisis-priority-lane + TASK-3b-4 crisis clinical-incident
    # signal). Nil when the worker is invoked without the patient
    # context (e.g., a direct test invocation, or a future admin
    # retry path that doesn't have the patient in scope).
    patient_id = Map.get(args, "patient_id")
    message_id = Map.get(args, "message_id")

    # 1. Pacer acquire. Blocks until tokens are available (1 msg/s/chat
    #    AND 30 msg/s global). The Pacer does NOT raise — it sleeps
    #    inside the GenServer and returns `:ok` when the token is
    #    granted. **This call is invariant across lanes** — the crisis
    #    lane MUST also acquire a Pacer token; the rate-limit is the
    #    safety net that REQ-C7-crisis-priority-lane depends on.
    Pacer.acquire(chat_id_hash)

    # 2. Decide whether this execution may send (#390). Done after the
    #    Pacer wait so a claim is held for the send only.
    case begin_delivery(message_id, lane) do
      {:skip, state} ->
        Logger.info(
          "TelegramOutboundWorker: reply not sent, delivery already decided " <>
            "(chat_id_hash_prefix=#{LogRedactor.prefix(chat_id_hash)}, delivery_state=#{state})"
        )

        :ok

      delivery ->
        # 3. Send.
        case telegram_client().send_message(chat_id, body) do
          {:ok, telegram_message_id} ->
            record_delivery(delivery, message_id, {:sent, telegram_message_id})
            :ok

          {:error, reason} ->
            handle_send_error(reason, delivery, %{
              args: args,
              attempt: attempt,
              lane: lane,
              priority: priority,
              chat_id_hash: chat_id_hash,
              patient_id: patient_id,
              message_id: message_id,
              body: body
            })
        end
    end
  end

  # A claimed journaling reply whose error does not prove non-delivery:
  # the request may have reached Telegram. Record it and stop — no
  # reschedule, no dead-letter, no resend.
  defp handle_send_error(reason, :claimed = delivery, ctx) do
    if Client.not_delivered?(reason) do
      retry_or_dead_letter(reason, delivery, ctx)
    else
      record_delivery(delivery, ctx.message_id, :ambiguous)

      Logger.warning(
        "TelegramOutboundWorker: ambiguous delivery outcome, reply will not be resent " <>
          "(chat_id_hash_prefix=#{LogRedactor.prefix(ctx.chat_id_hash)}, " <>
          "message_id=#{ctx.message_id}, outcome=#{outcome_label(reason)})"
      )

      :ok
    end
  end

  # Untracked jobs and the crisis lane: every error is retried up to the
  # budget, exactly as before #390.
  defp handle_send_error(reason, delivery, ctx), do: retry_or_dead_letter(reason, delivery, ctx)

  defp retry_or_dead_letter(reason, delivery, %{attempt: attempt} = ctx)
       when attempt >= @max_attempts do
    dead_letter_and_broadcast(
      ctx.chat_id_hash,
      ctx.patient_id,
      ctx.body,
      reason,
      attempt,
      ctx.lane
    )

    record_delivery(delivery, ctx.message_id, :failed)
    :ok
  end

  defp retry_or_dead_letter(reason, :claimed, ctx) do
    # The claim is released and the retry scheduled atomically: a retry
    # job never finds its own reply still claimed (which it would have to
    # treat as ambiguous), and a released reply always has its retry.
    {:ok, :ok} =
      Repo.transaction(fn ->
        Clinical.record_telegram_delivery(ctx.message_id, :not_sent)
        reschedule_after(reason, ctx)
      end)

    :ok
  end

  defp retry_or_dead_letter(reason, _delivery, ctx), do: reschedule_after(reason, ctx)

  defp reschedule_after(reason, ctx) do
    reschedule(
      ctx.args,
      ctx.attempt + 1,
      compute_backoff_ms(ctx.attempt, reason),
      ctx.lane,
      ctx.priority
    )
  end

  # ----------------------------------------------------------------
  # Delivery state of persisted replies (#390)
  # ----------------------------------------------------------------

  # Returns how this execution relates to the reply row:
  #   :untracked — no tracked row; legacy lifecycle.
  #   :claimed   — journaling lane; this execution holds the claim.
  #   :crisis    — crisis lane; tracked, sent without a claim.
  #   {:skip, state} — must not send.
  defp begin_delivery(message_id, lane) do
    cond do
      not tracked_message_id?(message_id) -> :untracked
      crisis_lane?(lane) -> begin_crisis_delivery(message_id)
      true -> begin_journaling_delivery(message_id)
    end
  end

  defp begin_crisis_delivery(message_id) do
    case Clinical.telegram_delivery_state(message_id) do
      nil -> :untracked
      "sent" -> {:skip, "sent"}
      _state -> :crisis
    end
  end

  defp begin_journaling_delivery(message_id) do
    case Clinical.claim_telegram_delivery(message_id) do
      :claimed ->
        :claimed

      {:not_claimed, nil} ->
        :untracked

      {:not_claimed, "sending"} ->
        # Another execution claimed this reply and has not recorded an
        # outcome: it is either still in flight or died mid-send. Either
        # way the request may have reached Telegram, so this execution
        # must not send. If the holder is alive it overrides this mark
        # with what it actually observed.
        Clinical.record_telegram_delivery(message_id, :ambiguous)
        {:skip, "ambiguous"}

      {:not_claimed, state} ->
        {:skip, state}
    end
  end

  defp record_delivery(:untracked, _message_id, _outcome), do: :ok

  defp record_delivery(_delivery, message_id, outcome) do
    Clinical.record_telegram_delivery(message_id, outcome)
    :ok
  end

  defp tracked_message_id?(message_id) when is_binary(message_id),
    do: match?({:ok, _}, Ecto.UUID.cast(message_id))

  defp tracked_message_id?(_message_id), do: false

  defp crisis_lane?(lane), do: lane == :crisis or lane == "crisis"

  # A fixed vocabulary for the log line: never `inspect/1` an unknown
  # error term, which could echo a response body.
  defp outcome_label({:ambiguous, reason}) when is_atom(reason), do: "ambiguous:#{reason}"

  defp outcome_label({:server_error, status}) when is_integer(status),
    do: "server_error:#{status}"

  defp outcome_label(_reason), do: "unknown"

  @doc """
  Inline, queue-bypassing send invoked by the inbound worker's
  queue-full escalation (REQ-C7-crisis-queue-full-escalation).

  Runs the same body as `perform/1` — `Pacer.acquire/1` then
  `Client.send_message/2` — but inline in the caller process (no Oban
  queue). On send failure, **dead-letters immediately** because the
  queue is full by definition (that's why we're inline); a retry
  would just hit the same `queue_full` error.

  ## Why not retry inline?

  Retrying inline (sleep + retry) would block the inbound worker for
  up to `@max_backoff_ms` (5 min). The whole point of the crisis
  lane is to move fast — the queue is full because the system is
  under load, and the right thing to do is fall back to the
  dead-letter + `ops:alerts` broadcast so an operator can replay
  manually. A `Logger.warning` documents the path.

  ## Args shape

  Same args shape as `perform/1`'s `args` field — `%{chat_id_hash,
  chat_id, message_id, body, lane, priority, _attempt}`. `_attempt` is
  unused in inline mode (no retry).
  """
  @spec perform_now(map()) :: :ok | {:error, term()}
  def perform_now(args) do
    # String keys (matches the Oban Job contract — args come from
    # JSON-decoded oban_jobs.args after Oban re-hydrates the job).
    # The inbound worker converts its in-process atom-keyed args to
    # string keys before calling this function (see
    # `escalate_to_perform_now/2` in `TelegramMessageWorker`).
    chat_id = Map.fetch!(args, "chat_id")
    chat_id_hash = Map.fetch!(args, "chat_id_hash")
    body = Map.fetch!(args, "body")
    lane = Map.get(args, "lane", :safe)
    patient_id = Map.get(args, "patient_id")
    message_id = Map.get(args, "message_id")

    Pacer.acquire(chat_id_hash)

    case begin_delivery(message_id, lane) do
      {:skip, _state} ->
        # The reply already has its outcome (e.g. an acknowledged crisis
        # reply re-escalated by a repeated inbound job): nothing to send.
        :ok

      delivery ->
        perform_now_send(delivery, message_id, chat_id, chat_id_hash, body, lane, patient_id)
    end
  end

  defp perform_now_send(delivery, message_id, chat_id, chat_id_hash, body, lane, patient_id) do
    case telegram_client().send_message(chat_id, body) do
      {:ok, telegram_message_id} ->
        record_delivery(delivery, message_id, {:sent, telegram_message_id})
        :ok

      {:error, reason} ->
        # Inline mode: no queue to reschedule to → dead-letter
        # immediately. attempt is 1 because the inline call ran once.
        # Return `{:error, reason}` so the caller (escalation path)
        # can distinguish a successful send from a dead-lettered
        # failure — the `:crisis_queue_full` PubSub broadcast carries
        # the outcome so operator dashboards don't react to a "queue
        # full" event and replay an already-succeeded send.
        dead_letter_and_broadcast(chat_id_hash, patient_id, body, reason, 1, lane)
        record_delivery(delivery, message_id, :failed)
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------
  # Backoff computation
  # ----------------------------------------------------------------

  # 429 with Retry-After → use the header value (in seconds) ± jitter.
  defp compute_backoff_ms(_attempt, {:rate_limited, retry_after_seconds})
       when is_integer(retry_after_seconds) and retry_after_seconds > 0 do
    base_ms = retry_after_seconds * 1_000
    apply_jitter(base_ms)
  end

  # 5xx / network / unknown → exponential backoff capped at @max_backoff_ms.
  defp compute_backoff_ms(attempt, _reason) do
    exponent = max(attempt - 1, 0)
    base_ms = min(@base_backoff_ms * Integer.pow(2, exponent), @max_backoff_ms)
    apply_jitter(base_ms)
  end

  # ± 25% jitter: `base_ms + (rand - 0.5) * 2 * 0.25 * base_ms`.
  # The lower bound is `base_ms * (1 - jitter_ratio)`; the upper bound
  # is `base_ms * (1 + jitter_ratio)`.
  defp apply_jitter(base_ms) do
    spread = trunc(base_ms * @jitter_ratio)
    jitter = :rand.uniform(spread * 2 + 1) - spread - 1
    max(base_ms + jitter, 0)
  end

  # ----------------------------------------------------------------
  # Rescheduling
  # ----------------------------------------------------------------

  defp reschedule(args, next_attempt, delay_ms, lane, priority) do
    scheduled_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    new_args = Map.put(args, "_attempt", next_attempt)

    # The queue is selected by the lane. Crisis retries stay on the
    # crisis lane (REQ-C7-crisis-priority-lane); safe retries stay on
    # the safe lane. The `lane` value can be either the atom (`:crisis`
    # | `:safe`) when the inbound worker passes it in-process, or the
    # string (`"crisis"` | `"safe"`) when JSON-decoded from `oban_jobs.args`
    # after a round-trip — both forms must be accepted so retries stay
    # on their lane.
    queue =
      case lane do
        :crisis -> :telegram_outbound_crisis
        "crisis" -> :telegram_outbound_crisis
        _ -> :telegram_outbound
      end

    new_args
    |> new(scheduled_at: scheduled_at, queue: queue, priority: priority)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("TelegramOutboundWorker: failed to reschedule (reason=#{inspect(reason)})")

        :ok
    end
  end

  # ----------------------------------------------------------------
  # Dead-letter + PubSub broadcast
  # ----------------------------------------------------------------

  defp dead_letter_and_broadcast(chat_id_hash, patient_id, body, reason, attempt, lane) do
    last_error = inspect(reason)

    # Normalize the lane to a string for the persisted column. The
    # function accepts both atom (`:crisis` | `:safe`) and string
    # (`"crisis"` | `"safe"`) values — see the rationale in the
    # `:crisis_dead_letter` broadcast block below.
    lane_str =
      case lane do
        :crisis -> "crisis"
        "crisis" -> "crisis"
        :safe -> "safe"
        "safe" -> "safe"
        _ -> "safe"
      end

    # The persisted audit row keeps the raw `inspect(reason)` so an
    # operator can replay failures with full diagnostic context. The
    # `LogRedactor.redact/1` wrappers on the broadcast + log
    # interpolation sites defend against future error shapes that
    # accidentally carry PHI (e.g., a future adapter returning
    # `%{chat_id: ...}` or `%{response_body: ...}` in the error tuple).
    # Today `inspect(reason)` only carries safe atoms/tuples, but the
    # redactor is a defense-in-depth guarantee — and it's a no-op when
    # no 64-char hex is present.
    safe_error = LogRedactor.redact(last_error)

    {:ok, _row} =
      %OutboundDeadLetter{}
      |> OutboundDeadLetter.changeset(%{
        chat_id_hash: chat_id_hash,
        text: body,
        last_error: last_error,
        attempts: attempt,
        failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        # Round 1 (judgment-day, WARNING-5): persist the lane and
        # patient_id so the operator query surface mirrors the
        # PubSub event. `patient_id` is nil for unbound-chat
        # dead-letters (the "unregistered" copy path).
        lane: lane_str,
        patient_id: patient_id
      })
      |> Repo.insert()

    now = DateTime.utc_now()

    # Generic dead-letter event (PR #3a — every dead-letter, regardless
    # of lane). Dashboards use this to show a unified "what failed" view.
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      "ops:alerts",
      {:outbound_dead_letter,
       %{
         chat_id_hash: chat_id_hash,
         text: body,
         error: safe_error,
         attempts: attempt,
         # Round 1 (WARNING-5): the lane is normalized to a string
         # here so the broadcast matches the persisted column. The
         # function-internal `lane` (atom or string) is normalized
         # once into `lane_str` for both the DB insert and the
         # broadcast.
         lane: lane_str,
         at: now
       }}
    )

    # Crisis-specific clinical-incident event (TASK-3b-4). Crisis
    # dead-letters are clinical incidents (the patient is in distress
    # and the support message couldn't reach them) and warrant a
    # DISTINCT signal so operator dashboards can prioritize them over
    # safe-lane failures. The `:crisis_dead_letter` event carries the
    # foundation `patient_id` so the dashboard can correlate to the
    # patient record (the chat_id_hash alone is the rate-limit key —
    # it correlates to a patient but the operator wants the UUID).
    #
    # Both events fire for crisis lane dead-letters. The generic event
    # is for unified dead-letter views; the crisis event is for the
    # clinical-incident dashboard.
    # The lane may be `:crisis` (atom, set in-process) or `"crisis"`
    # (string, after a JSON round-trip via Oban args) — both forms are
    # accepted so a crisis dead-letter always broadcasts the
    # clinical-incident signal (TASK-3b-4).
    if lane == :crisis or lane == "crisis" do
      Phoenix.PubSub.broadcast(
        Alethea.PubSub,
        "ops:alerts",
        {:crisis_dead_letter,
         %{
           patient_id: patient_id,
           chat_id_hash: chat_id_hash,
           text: body,
           error: safe_error,
           attempts: attempt,
           at: now
         }}
      )
    end

    Logger.error(
      "TelegramOutboundWorker: exhausted retries, dead-letter written " <>
        "(chat_id_hash_prefix=#{LogRedactor.prefix(chat_id_hash)}, " <>
        "attempts=#{attempt}, lane=#{lane}, error=#{safe_error})"
    )

    :ok
  end

  # ----------------------------------------------------------------
  # Config adapter resolution
  # ----------------------------------------------------------------

  defp telegram_client do
    Application.get_env(:alethea, :telegram_client, Client.Fake)
  end
end
