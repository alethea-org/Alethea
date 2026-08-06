defmodule Alethea.Clinical.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field(:direction, :string)
    field(:behavior_type, :string, default: "spontaneous")
    # Telegram inbound traceability (REQ-C3-worker-persists-message).
    # Nullable because not every channel writes one. Partial unique index
    # `messages_telegram_message_id_unique` enforces "at most one
    # inbound row per Telegram message_id" while leaving the column
    # `NULL` for rows from other channels (migration
    # `20260620000001_add_telegram_message_id_to_messages.exs`).
    field(:telegram_message_id, :string)
    field(:encrypted_content, :binary)
    field(:encryption_version, :integer, default: 1)
    field(:synced_to_graph, :boolean, default: false)
    field(:timestamp, :utc_datetime)

    belongs_to(:patient, Alethea.Accounts.Patient)
    belongs_to(:session, Alethea.Clinical.Session)
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
      name: :messages_telegram_message_id_unique
    )
  end
end
