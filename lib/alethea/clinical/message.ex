defmodule Alethea.Clinical.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field(:direction, :string)
    field(:behavior_type, :string, default: "spontaneous")
    # Telegram inbound traceability (REQ-C3-worker-persists-message).
    # Nullable because not every channel writes one. Telegram message ids
    # are counters per chat, so the identity is scoped to the patient's
    # conversation: partial unique index
    # `messages_patient_telegram_message_id_unique` on
    # `(patient_id, telegram_message_id)` enforces "at most one row per
    # Telegram message in a patient's chat" while leaving the column
    # `NULL` for rows from other channels (issue #390).
    field(:telegram_message_id, :string)
    field(:encrypted_content, :binary)
    field(:encryption_version, :integer, default: 1)
    field(:synced_to_graph, :boolean, default: false)
    field(:timestamp, :utc_datetime)

    belongs_to(:patient, Alethea.Accounts.Patient)
    belongs_to(:session, Alethea.Clinical.Session)
    # Reply provenance (#390): set on an outbound Telegram reply, pointing
    # at the inbound message that caused it. Set programmatically (never
    # cast). Partial unique index `messages_reply_to_message_id_unique`
    # guarantees at most one reply row per inbound.
    belongs_to(:reply_to_message, __MODULE__)
    has_many(:ai_diagnoses, Alethea.AI.Diagnosis)
    has_one(:emotion_analysis, Alethea.Clinical.EmotionAnalysis)

    # embedding vector(384) column added manually once pgvector is installed on the PG server

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :direction,
      :behavior_type,
      :telegram_message_id,
      :encrypted_content,
      :encryption_version,
      :synced_to_graph,
      :timestamp,
      :patient_id,
      :session_id
    ])
    |> validate_required([
      :direction,
      :behavior_type,
      :encrypted_content,
      :timestamp,
      :patient_id
    ])
    |> validate_inclusion(:direction, ["inbound", "outbound"])
    # `crisis_bypass` was added in PR #3b (TASK-3b-1) per REQ-C5-persist-outbound-reply
    # "crisis reply is persisted with crisis_bypass source". The DB-side check
    # constraint was widened in migration
    # `20260622000001_add_crisis_bypass_to_message_behavior_type.exs`; the
    # Ecto-level validate_inclusion is kept in lockstep with the DB constraint.
    |> validate_inclusion(:behavior_type, ["spontaneous", "elicited", "crisis_bypass"])
    |> unique_constraint(:telegram_message_id,
      name: :messages_patient_telegram_message_id_unique
    )
    |> unique_constraint(:reply_to_message_id, name: :messages_reply_to_message_id_unique)
  end
end
