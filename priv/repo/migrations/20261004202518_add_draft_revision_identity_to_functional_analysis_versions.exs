defmodule Alethea.Repo.Migrations.AddDraftRevisionIdentityToFunctionalAnalysisVersions do
  use Ecto.Migration

  def change do
    alter table(:functional_analysis_versions) do
      add :source_draft_lock_version, :integer, null: true
    end

    create unique_index(
             :functional_analysis_versions,
             [:draft_id, :source_draft_lock_version],
             name: :functional_analysis_versions_draft_revision_index
           )
  end
end
