defmodule Alethea.Repo.Migrations.AddStructuredFieldsToClinicalSummaries do
  use Ecto.Migration

  def change do
    alter table(:clinical_summaries) do
      add :anxiety_score, :float
      add :social_score, :float
      add :emotional_range, :map
      add :crisis_events, :integer
      add :session_count, :integer
    end
  end
end
