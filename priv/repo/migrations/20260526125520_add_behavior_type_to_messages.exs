defmodule Alethea.Repo.Migrations.AddBehaviorTypeToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :behavior_type, :string, null: false, default: "spontaneous"
      add :whatsapp_message_id, :string
    end

    create constraint(:messages, :behavior_type_must_be_valid, check: "behavior_type IN ('spontaneous', 'elicited')")
    create unique_index(:messages, [:whatsapp_message_id], where: "whatsapp_message_id IS NOT NULL")
  end
end
