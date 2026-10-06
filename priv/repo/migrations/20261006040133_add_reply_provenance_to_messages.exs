defmodule Alethea.Repo.Migrations.AddReplyProvenanceToMessages do
  @moduledoc """
  Records which inbound message caused an outbound Telegram reply
  (issue #390).

  `reply_to_message_id` is set on the outbound reply row and points at the
  inbound row. The partial unique index makes "one logical reply per
  inbound" a database guarantee: concurrent executions of the same inbound
  job race on it, and the loser reuses the winner's reply instead of
  persisting a second one.

  The column is an internal row reference (no clinical content). Rows
  written before this migration keep `NULL` and are ignored by the index.
  """

  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :reply_to_message_id, references(:messages, type: :binary_id, on_delete: :nothing)
    end

    create unique_index(:messages, [:reply_to_message_id],
             where: "reply_to_message_id IS NOT NULL",
             name: :messages_reply_to_message_id_unique
           )
  end
end
