defmodule Alethea.Repo.Migrations.CreateAiProposals do
  use Ecto.Migration

  # `ai_proposals` rows are mutable via `AIProposal.update_changeset/2`
  # (encrypted_text + status only — encrypted_original_text is write-once,
  # design D3). No DB-level immutability trigger here (unlike
  # `consultation_evidences`): the write-once guarantee for
  # `encrypted_original_text` is enforced structurally, by the schema
  # never casting that column on update
  # (sdd/alethea/issue-195-clinical-review-workbench, PR1b).
  def change do
    create table(:ai_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :encrypted_original_text, :binary, null: false
      add :encrypted_text, :binary, null: false
      add :status, :string, null: false
      add :model_version, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Requester of the generation, not necessarily the later
      # accepter/editor/discarder.
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      add :target_behavior_id,
          references(:target_behaviors, on_delete: :delete_all, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ai_proposals, [:target_behavior_id, :occurred_at])
    create index(:ai_proposals, [:patient_id])

    create constraint(:ai_proposals, :status_must_be_valid,
             check: "status IN ('pending', 'edited', 'accepted', 'discarded')"
           )
  end
end
