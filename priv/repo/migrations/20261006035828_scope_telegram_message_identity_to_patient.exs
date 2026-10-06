defmodule Alethea.Repo.Migrations.ScopeTelegramMessageIdentityToPatient do
  @moduledoc """
  Scopes the Telegram inbound identity to the patient's conversation
  (issue #390).

  Telegram `message_id` values are counters per chat, so two patients can
  legitimately receive the same value. The previous global partial unique
  index `messages_telegram_message_id_unique` made the second patient's
  inbound fail. A patient has exactly one Telegram chat (the chat hash
  lives on `foundation_patients`), so `patient_id` is the conversation
  scope and no chat identifier is added to `messages`.

  Every row that satisfied the global index also satisfies the composite
  one, so `up` needs no backfill. `down` restores the global index and
  fails if two patients already share a Telegram message id.
  """

  use Ecto.Migration

  def up do
    drop index(:messages, [:telegram_message_id], name: :messages_telegram_message_id_unique)

    create unique_index(:messages, [:patient_id, :telegram_message_id],
             where: "telegram_message_id IS NOT NULL",
             name: :messages_patient_telegram_message_id_unique
           )
  end

  def down do
    drop index(:messages, [:patient_id, :telegram_message_id],
           name: :messages_patient_telegram_message_id_unique
         )

    create unique_index(:messages, [:telegram_message_id],
             where: "telegram_message_id IS NOT NULL",
             name: :messages_telegram_message_id_unique
           )
  end
end
