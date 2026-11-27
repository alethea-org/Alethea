defmodule Alethea.Repo.Migrations.RedactOutboundDeadLetterText do
  @moduledoc """
  Stops `foundation_outbound_dead_letters` from holding reply bodies in
  clear (security-audit-run-2, S2).

  `up/0`:

    1. Adds `message_id`, a reference to the reply row whose content
       stays encrypted under the patient key in `messages`. It has no
       foreign key, like `patient_id` before it was added: dead letters
       for untracked sends (unregistered chat, onboarding, reminders)
       have no message row.
    2. Makes `text` nullable and clears every existing body
       (`clear_plaintext_text!/1`). The application no longer writes the
       column; it stays only so this migration can be reverted.

  `down/0` drops `message_id` and restores `text NOT NULL`, filling the
  cleared rows with a placeholder. The original bodies are not
  recoverable: erasing them is the point of this migration.
  """

  use Ecto.Migration

  @placeholder "[redacted]"

  @doc false
  def clear_plaintext_text!(repo) do
    repo.query!("UPDATE foundation_outbound_dead_letters SET text = NULL WHERE text IS NOT NULL")
    :ok
  end

  def up do
    alter table(:foundation_outbound_dead_letters) do
      add :message_id, :binary_id
      modify :text, :text, null: true, from: {:text, null: false}
    end

    flush()
    clear_plaintext_text!(repo())
  end

  def down do
    execute(
      "UPDATE foundation_outbound_dead_letters SET text = '#{@placeholder}' WHERE text IS NULL"
    )

    alter table(:foundation_outbound_dead_letters) do
      remove :message_id
      modify :text, :text, null: false, from: {:text, null: true}
    end
  end
end
