defmodule Alethea.Repo.Migrations.AddMediaTypeToMessages do
  use Ecto.Migration

  # Telegram voice notes (odd/tasks/telegram-voice-notes.md, S2): an inbound
  # message transcribed from a patient's voice note is marked "voice". `NULL`
  # means a written message (every row before this migration). Additive and
  # nullable, so existing rows and writers are untouched.
  def change do
    alter table(:messages) do
      add :media_type, :string
    end

    create constraint(:messages, :messages_media_type_check,
             check: "media_type IS NULL OR media_type IN ('voice')"
           )
  end
end
