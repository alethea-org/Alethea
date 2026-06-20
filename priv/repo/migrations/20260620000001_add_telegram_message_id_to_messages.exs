defmodule Alethea.Repo.Migrations.AddTelegramMessageIdToMessages do
  @moduledoc """
  Adds the `telegram_message_id` column to the `messages` table for the
  Telegram channel's inbound message traceability.

  Per REQ-C3-worker-persists-message, every inbound Telegram `Message`
  row carries the upstream Telegram `message_id` (the bot's monotonic
  counter per chat). The column mirrors `whatsapp_message_id` —
  nullable because not every channel writes one — and is paired with a
  partial unique index that enforces "at most one inbound row per
  Telegram message_id" while allowing the column to be `NULL` for
  rows that originate from another channel (the existing
  WhatsApp-only rows).

  ## Why a partial unique index (not a plain unique)

  Mirrors the design of `whatsapp_message_id` (PR #2-era migration
  `20260526125520_add_behavior_type_to_messages.exs`) and the
  `foundation_patients.telegram_chat_id_hash` partial unique index
  (migration `20260618234145_rename_telegram_chat_id_to_hash.exs`).
  PostgreSQL allows multiple `NULL`s in a plain unique index; the
  `WHERE telegram_message_id IS NOT NULL` clause documents the
  intent: the unique constraint applies only to bound Telegram
  messages. Pre-existing rows that did not carry a
  `telegram_message_id` do not consume a unique slot.

  ## Out of scope

  - The `whatsapp_message_id` column and its index are untouched.
  - No backfill: existing rows have `telegram_message_id = NULL`
    which the partial index ignores.
  """

  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :telegram_message_id, :string
    end

    create unique_index(:messages, [:telegram_message_id],
             where: "telegram_message_id IS NOT NULL",
             name: :messages_telegram_message_id_unique
           )
  end
end
