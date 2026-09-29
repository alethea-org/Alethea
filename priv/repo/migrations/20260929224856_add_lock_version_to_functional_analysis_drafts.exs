defmodule Alethea.Repo.Migrations.AddLockVersionToFunctionalAnalysisDrafts do
  use Ecto.Migration

  def change do
    alter table(:functional_analysis_drafts) do
      add :lock_version, :integer, default: 1, null: false
    end
  end
end
