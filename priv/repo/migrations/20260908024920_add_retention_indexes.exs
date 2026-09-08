defmodule Alethea.Repo.Migrations.AddRetentionIndexes do
  use Ecto.Migration

  def change do
    create index(:target_behaviors, [:inserted_at])
    create index(:clinical_notes, [:inserted_at])
    create index(:consultation_evidences, [:inserted_at])
    create index(:clinician_observations, [:updated_at])
    create index(:ai_proposals, [:updated_at])
    create index(:functional_analysis_drafts, [:updated_at])
  end
end
