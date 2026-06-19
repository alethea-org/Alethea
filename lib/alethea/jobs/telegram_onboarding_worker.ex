defmodule Alethea.Jobs.TelegramOnboardingWorker do
  @moduledoc """
  Oban worker stub for the Telegram `/start` onboarding flow (C-1 → C-4).

  Receives `%{telegram_update_id: integer, token: binary() | nil}` and is
  responsible for binding the chat to a `Patient` row. The `token` (if
  present) is the deep-link token minted by `Alethea.Telegram.DeepLinkToken`
  and persisted by `Alethea.Foundation.Accounts.PatientAuthCode` (PR #4);
  a `nil` token means the patient opened the chat cold (no professional
  pre-minted a link) and the worker should walk them through the manual
  onboarding path.

  ## Stub status (TASK-2-3)

  Lands as a minimal stub in TASK-2-3 so the webhook controller can
  enqueue a real `Oban.Job` row for `/start` messages. The full body —
  token verification, patient binding via `Accounts.bind_patient_to_chat/2`,
  welcome message, outbound dispatch — lands in TASK-2-7 / PR #3a. The
  stub's `perform/1` returns `:ok` so the Oban state machine treats it
  as a successful job and does not retry.

  ## Queue + uniqueness

    - Queue: `:telegram_inbound` (same queue as `TelegramMessageWorker`).
      The controller decides which worker to enqueue; the queue carries
      both flows.
    - Unique: NONE. `/start` is safe to re-enqueue — the deep-link token
      is single-use at the DB layer (PR #4), so a duplicate enqueue
      cannot bind a chat twice. A unique constraint here would be
      redundant and would mask genuine retries (e.g. a worker that
      crashed mid-bind).

  ## R-1 (PHI hygiene)

  The args map carries the `telegram_update_id` (safe — it's Telegram's
  monotonic counter, not patient data) and optionally the `token` (a
  random opaque value, NOT the patient id). The stub does not log the
  args; the full worker (PR #3a) handles the PHI-bearing bindings.
  """
  use Oban.Worker,
    queue: :telegram_inbound,
    max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Stub body. PR #3a (TelegramOnboardingWorker) will:
    #   1. if token present, look up PatientAuthCode via Accounts module
    #      (PR #4 schema), verify TTL, single-use, attempt_count
    #   2. hash chat_id via Alethea.Telegram.ChatIdHash.hash/2
    #   3. bind the patient to the chat (Accounts.bind_patient_to_chat/2)
    #   4. dispatch the outbound worker with the welcome message
    _ = args
    :ok
  end
end
