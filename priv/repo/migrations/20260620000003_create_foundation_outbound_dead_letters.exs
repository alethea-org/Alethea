defmodule Alethea.Repo.Migrations.CreateFoundationOutboundDeadLetters do
  @moduledoc """
  Creates the `foundation_outbound_dead_letters` table for the Telegram
  outbound worker's exhaustion path (REQ-C7-dead-letter-on-exhaustion).

  When the `TelegramOutboundWorker` exhausts its retry budget on a
  chat_id_hash (5 consecutive 429 / 5xx / network failures), the
  payload — chat_id_hash, text, last error, attempt count, and the
  timestamp of exhaustion — is written to this table so the operator
  can audit or replay. The worker also broadcasts a
  `{:outbound_dead_letter, …}` event on `"ops:alerts"` for live
  monitoring.

  ## Why a foundation_* table

  The dead-letter row is a Telegram-channel artefact (the `chat_id_hash`
  is the Telegram-specific HMAC-SHA256 of the chat identifier, not
  the legacy `whatsapp_number_hash`). Per the foundation/legacy
  split (see `Alethea.Foundation.Accounts.Patient` moduledoc), new
  channel-specific tables go under `foundation_*`. There is no legacy
  `outbound_dead_letters` table; this is a fresh schema.

  ## Why no FK to patients / messages

  The dead-letter is intentionally decoupled from the patient identity:
  a dead-letter row may exist for an unbound chat (e.g., a 5-retry
  exhaustion on the "unregistered" outbound copy enqueued by
  `TelegramMessageWorker`). FK-ing to `messages` or `patients` would
  reject that case. The `chat_id_hash` is the only link; the row is
  audit-only and has no cascading deletes.

  ## No encryption on `text`

  The `text` column is stored in plaintext (the patient's own words).
  The Telegram outbound worker writes this from the Oban job args,
  which are NOT encrypted at rest. This is consistent with the rest
  of the `messages.encrypted_content` PHI hygiene: the dead-letter is
  a debug / replay surface, not a clinical record. Access is
  controlled by the audit_logs RBAC story (out of scope here; the
  dead-letter table is read by operators via a future admin LiveView,
  PR #4 follow-up).
  """

  use Ecto.Migration

  def change do
    create table(:foundation_outbound_dead_letters, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 64-char lowercase hex per `Alethea.Telegram.ChatIdHash.hash/2`.
      # No partial index here — the column is required, and the same
      # hash can dead-letter multiple distinct outbound payloads over
      # time (e.g., a flaky network leaves a trail).
      add :chat_id_hash, :string, null: false

      # The outbound message body. Plaintext by design (see moduledoc).
      add :text, :text, null: false

      # The error term from the last Client.send_message/2 call,
      # stringified for human audit (e.g.,
      # `"{:rate_limited, 2}"` or `"{:server_error, 503}"`).
      add :last_error, :text, null: false

      # How many attempts ran before exhaustion. The spec caps at 5
      # but the column records the actual count for audit (a future
      # config change to max_attempts must not invalidate old rows).
      add :attempts, :integer, null: false

      # When exhaustion was recorded (UTC). Index for the "recent
      # dead-letters" admin view's `ORDER BY failed_at DESC LIMIT 50`.
      add :failed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:foundation_outbound_dead_letters, [:chat_id_hash])
    create index(:foundation_outbound_dead_letters, [:failed_at])
  end
end
