defmodule Alethea.Jobs.TelegramMessageWorker do
  @moduledoc """
  Oban worker stub for inbound Telegram messages (C-1 → C-3 / PR #3a).

  Receives the full Telegram `Update.message` JSON (with the raw `chat.id`
  still in plaintext — the worker is responsible for HMAC-hashing it via
  `Alethea.Telegram.ChatIdHash.hash/2` before any DB lookup or log line).

  ## Stub status (TASK-2-3)

  This file lands as a minimal stub in TASK-2-3 so the webhook
  controller can enqueue a real `Oban.Job` row. The full body — patient
  lookup by `chat_id_hash`, clinical routing, AI response, outbound
  dispatch — lands in TASK-2-7 / PR #3a. The stub's `perform/1`
  returns `:ok` so the Oban state machine treats it as a successful
  job and does not retry.

  ## Queue + uniqueness (R-3)

    - Queue: `:telegram_inbound` (configured in `config/config.exs`).
      Same queue as `TelegramOnboardingWorker` — the routing decision
      (message vs. onboarding) lives at the controller level, not at
      the queue level. A future high-priority / low-priority split
      would add a separate queue, not a worker re-org.
    - Unique: 24h, keyed on `args.telegram_update_id`. Telegram's
      `update_id` is a monotonic counter per bot, so the same value
      can only be re-used by a Telegram-side replay — the 24h window
      is the spec's documented replay-protection window. After 24h
      the row is eligible for a fresh insert, which is intentional:
      the system prefers to accept a stale replay over dropping a
      genuine message.

  ## R-1 (PHI hygiene)

  The args map carries the raw `chat_id` in `message.chat.id` (that's
  how Telegram's API delivers it). The stub does NOT log the args; the
  full worker (PR #3a) will hash the `chat_id` before any log line or
  DB lookup. The controller (TASK-2-3) also does not log the body.
  """
  use Oban.Worker,
    queue: :telegram_inbound,
    max_attempts: 5,
    unique: [period: 86_400, keys: [:telegram_update_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Stub body. PR #3a (TelegramMessageWorker) will:
    #   1. hash chat_id via Alethea.Telegram.ChatIdHash.hash/2
    #   2. look up the patient via Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1
    #   3. route to clinical / crisis path
    #   4. acquire Pacer tokens, build the Alethea response, dispatch
    #      the outbound worker
    _ = args
    :ok
  end
end
