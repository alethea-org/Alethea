defmodule Alethea.Repo.Migrations.AddFunctionalAnalysisVersionSequenceToTargetBehaviors do
  use Ecto.Migration

  def up do
    alter table(:target_behaviors) do
      add :functional_analysis_version_sequence, :integer
    end

    execute """
    UPDATE target_behaviors AS target
    SET functional_analysis_version_sequence = COALESCE(
      (
        SELECT MAX(version.version_number)
        FROM functional_analysis_versions AS version
        WHERE version.target_behavior_id = target.id
      ),
      0
    )
    """

    alter table(:target_behaviors) do
      modify :functional_analysis_version_sequence, :integer, default: 0, null: false
    end
  end

  def down do
    alter table(:target_behaviors) do
      remove :functional_analysis_version_sequence
    end
  end
end
