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

  The dead-letter table is **not** a clinical record. The `text`
  column is plaintext by design (see migration moduledoc). It is the
  replay / audit surface for an operator who needs to know "which
  outbound messages failed and why". A clinical-grade copy of the
  message lives on `messages.encrypted_content`; the dead-letter is a
  debug record of the network failure.

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
    field :text, :string
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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a new dead-letter row.
  """
  def changeset(dead_letter, attrs) do
    dead_letter
    |> cast(attrs, [:chat_id_hash, :text, :last_error, :attempts, :failed_at, :patient_id, :lane])
    |> validate_required([:chat_id_hash, :text, :last_error, :attempts, :failed_at, :lane])
    |> validate_length(:chat_id_hash, is: 64)
    |> validate_number(:attempts, greater_than: 0)
    |> validate_inclusion(:lane, ["safe", "crisis"])
  end
end
