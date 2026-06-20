defmodule Alethea.Jobs.TelegramOutboundWorker do
  @moduledoc """
  Oban worker that ships an outbound Telegram reply to the patient.

  ## Stub status (PR #3a / TASK-3a-1)

  This file lands as a minimal stub in TASK-3a-1 so the
  `TelegramMessageWorker` can enqueue a real `Oban.Job` row without
  a `UndefinedFunctionError` at compile time. The stub's
  `perform/1` returns `:ok` so the Oban state machine treats it as
  a successful job and does not retry.

  The full body — `Pacer.acquire/1` → `Client.send_message/2` → 429
  jittered backoff → dead-letter on exhaustion — lands in TASK-3a-2.
  The crisis-bypass `perform_now/1` escalation lands in PR #3b.

  ## Queue + uniqueness (R-2)

  - Queue: `:telegram_outbound` (PR #2 TASK-2-6). Per-chat and
    global Pacer limits apply at `perform/1` call-time, not at
    enqueue-time; multiple jobs for the same chat can sit in the
    queue and will be paced at run-time by the Pacer.

  - The worker's own args carry `chat_id_hash` (the same 64-char
    hex the inbound worker computed). The outbound worker passes
    the hash to `Pacer.acquire/1`; the raw chat_id never appears
    in `oban_jobs.args` because the inbound worker hashed it
    before enqueueing.

  ## R-1 (PHI hygiene)

  The stub does NOT log the args. The full worker (TASK-3a-2) will
  log the hash prefix only.
  """

  use Oban.Worker, queue: :telegram_outbound, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    # Stub body. TASK-3a-2 will:
    #   1. Pacer.acquire(chat_id_hash)   ── blocks until tokens available
    #   2. Client.send_message(chat_id, text)  ── Req in prod, Fake in test
    #   3. 429 → jittered exponential backoff (Retry-After + max_attempts)
    #   4. 5xx / network → schedule retry
    #   5. exhausted → TelegramDeadLetter row + PubSub :outbound_dead_letter
    :ok
  end
end
