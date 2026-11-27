defmodule Alethea.Foundation.Accounts.OutboundDeadLetter do
  @moduledoc """
  Foundation dead-letter row for an exhausted Telegram outbound send
  (REQ-C7-dead-letter-on-exhaustion).

  When `Alethea.Jobs.TelegramOutboundWorker` exhausts its retry budget
  (5 consecutive 429 / 5xx / network failures on the same chat), the
  payload is written here so the operator can audit or replay. The
  worker also broadcasts a `{:outbound_dead_letter, %{...}}` event on
  the `"ops:alerts"` Phoenix.PubSub topic for live monitoring.

  ## Schema vs `messages`

  The dead-letter table is **not** a clinical record and never holds
  the reply body (security-audit-run-2, S2). It is the audit surface
  for an operator who needs to know "which outbound messages failed
  and why": chat hash, patient, lane, outcome, error and, for a
  tracked reply, `message_id`, the row whose content stays encrypted
  under the patient key in `messages.encrypted_content`. The legacy
  `text` column is not mapped here and is always NULL
  (`RedactOutboundDeadLetterText` migration).

  ## No FK to patients

  Decoupled on purpose: a dead-letter row may exist for an unbound
  chat (e.g., a 5-retry exhaustion on the "unregistered" outbound
  copy). FK-ing to `messages` or `patients` would reject that case.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_outbound_dead_letters" do
    field :chat_id_hash, :string

    # The tracked reply (`messages.id`) this dead letter is about, or nil
    # for untracked sends (unregistered chat, onboarding, reminders). No
    # FK, for the same reason as `patient_id` (see moduledoc).
    field :message_id, :binary_id
    field :last_error, :string
    field :attempts, :integer
    field :failed_at, :utc_datetime

    # Foundation patient UUID. Round 1 (judgment-day, WARNING-5):
    # mirrors the PubSub event so operator queries can correlate the
    # dead-letter to the patient record without joining on the rate
    # limit key (`chat_id_hash`). Nullable — unbound-chat dead-letters
    # (the "unregistered" copy path) have no patient.
    field :patient_id, :binary_id

    # Lane discriminator. `"safe"` (the pre-PR-3b path) or `"crisis"`
    # (the PR #3b clinical-incident path). Mirrors the PubSub event's
    # `lane` field. DB check constraint enforces the two values.
    field :lane, :string

    # What is known about the delivery (issue #390). `"failed"`: the
    # message is known not to have arrived (retry budget exhausted).
    # `"ambiguous"`: the request may have reached Telegram and nobody
    # knows whether the patient received it; it was NOT resent, so an
    # operator must not replay it blindly either.
    field :outcome, :string, default: "failed"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a new dead-letter row.
  """
  def changeset(dead_letter, attrs) do
    dead_letter
    |> cast(attrs, [
      :chat_id_hash,
      :message_id,
      :last_error,
      :attempts,
      :failed_at,
      :patient_id,
      :lane,
      :outcome
    ])
    |> validate_required([:chat_id_hash, :last_error, :attempts, :failed_at, :lane])
    |> validate_length(:chat_id_hash, is: 64)
    |> validate_number(:attempts, greater_than: 0)
    |> validate_inclusion(:lane, ["safe", "crisis"])
    |> validate_inclusion(:outcome, ["failed", "ambiguous"])
  end
end
