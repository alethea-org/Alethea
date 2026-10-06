defmodule Alethea.Repo.Migrations.AddDeliveryStateToMessages do
  @moduledoc """
  Adds an explicit delivery outcome to outbound Telegram replies
  (issue #390).

    * `delivery_state` — `pending` (persisted, not yet sent), `sending`
      (claimed by one execution of the delivery job), `sent`
      (acknowledged by Telegram), `ambiguous` (the request may have
      reached Telegram; never resent), `failed` (retry budget exhausted
      before any send). `NULL` for rows that are not tracked Telegram
      replies (inbound, other channels, rows written before this
      migration).
    * `delivered_telegram_message_id` — the id Telegram returned for the
      delivered message. Deliberately separate from `telegram_message_id`
      (the inbound identity under a unique index) so recording an
      acknowledgement can never fail on a constraint.

  Both columns are non-sensitive delivery metadata; the reply content
  stays in the existing encrypted column.
  """

  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :delivery_state, :string
      add :delivered_telegram_message_id, :string
    end

    create constraint(:messages, :messages_delivery_state_check,
             check:
               "delivery_state IS NULL OR delivery_state IN " <>
                 "('pending', 'sending', 'sent', 'ambiguous', 'failed')"
           )
  end
end
