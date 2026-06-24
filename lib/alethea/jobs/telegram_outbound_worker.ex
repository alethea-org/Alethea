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

    # 1. Pacer acquire. Blocks until tokens are available (1 msg/s/chat
    #    AND 30 msg/s global). The Pacer does NOT raise — it sleeps
    #    inside the GenServer and returns `:ok` when the token is
    #    granted. **This call is invariant across lanes** — the crisis
    #    lane MUST also acquire a Pacer token; the rate-limit is the
    #    safety net that REQ-C7-crisis-priority-lane depends on.
    Pacer.acquire(chat_id_hash)

    # 2. Send.
    case telegram_client().send_message(chat_id, body) do
      {:ok, _message_id} ->
        :ok

      {:error, reason} when attempt >= @max_attempts ->
        dead_letter_and_broadcast(chat_id_hash, patient_id, body, reason, attempt, lane)
        :ok

      {:error, reason} ->
        reschedule(args, attempt + 1, compute_backoff_ms(attempt, reason), lane, priority)
        :ok
    end
  end

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
  @spec perform_now(map()) :: :ok
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

    Pacer.acquire(chat_id_hash)

    case telegram_client().send_message(chat_id, body) do
      {:ok, _message_id} ->
        :ok

      {:error, reason} ->
        # Inline mode: no queue to reschedule to → dead-letter
        # immediately. attempt is 1 because the inline call ran once.
        dead_letter_and_broadcast(chat_id_hash, patient_id, body, reason, 1, lane)
        :ok
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
    # the safe lane.
    queue = if lane == :crisis, do: :telegram_outbound_crisis, else: :telegram_outbound

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

    {:ok, _row} =
      %OutboundDeadLetter{}
      |> OutboundDeadLetter.changeset(%{
        chat_id_hash: chat_id_hash,
        text: body,
        last_error: last_error,
        attempts: attempt,
        failed_at: DateTime.utc_now() |> DateTime.truncate(:second)
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
         error: last_error,
         attempts: attempt,
         lane: lane,
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
    if lane == :crisis do
      Phoenix.PubSub.broadcast(
        Alethea.PubSub,
        "ops:alerts",
        {:crisis_dead_letter,
         %{
           patient_id: patient_id,
           chat_id_hash: chat_id_hash,
           text: body,
           error: last_error,
           attempts: attempt,
           at: now
         }}
      )
    end

    Logger.error(
      "TelegramOutboundWorker: exhausted retries, dead-letter written " <>
        "(chat_id_hash_prefix=#{LogRedactor.prefix(chat_id_hash)}, " <>
        "attempts=#{attempt}, lane=#{lane}, error=#{last_error})"
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
