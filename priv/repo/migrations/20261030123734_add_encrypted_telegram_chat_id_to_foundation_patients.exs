defmodule Alethea.Repo.Migrations.AddEncryptedTelegramChatIdToFoundationPatients do
  @moduledoc """
  Adds nullable binary `encrypted_telegram_chat_id` to `foundation_patients` (ADR-011, #438).

  Stores the Telegram chat_id encrypted with the patient's data encryption key (DEK),
  enabling proactive scheduled messaging while keeping the chat_id subject to the same
  cryptographic erasure boundary as clinical journaling.
  """

  use Ecto.Migration

  def change do
    alter table(:foundation_patients) do
      add :encrypted_telegram_chat_id, :binary, null: true
    end
  end
end
