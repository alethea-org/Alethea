defmodule Alethea.Repo.Migrations.AddCitedEvidenceBaselineToFunctionalAnalysisVersions do
  use Ecto.Migration

  def change do
    alter table(:functional_analysis_versions) do
      add :encrypted_cited_evidence_baseline, :binary
    end
  end
end
