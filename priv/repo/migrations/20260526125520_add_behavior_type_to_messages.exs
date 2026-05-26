defmodule Alethea.Repo.Migrations.AddBehaviorTypeToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # spontaneous (iniciado por paciente), elicited (provocado por la IA)
      add :behavior_type, :string, null: false, default: "spontaneous"
      # Idempotencia: guardamos el ID que manda Meta
      add :whatsapp_message_id, :string
    end

    create unique_index(:messages, [:whatsapp_message_id])

    # Check constraint para behavior_type
    create constraint(:messages, :behavior_type_check,
             check: "behavior_type IN ('spontaneous', 'elicited')"
           )
  end
end
