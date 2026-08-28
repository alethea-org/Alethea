defmodule Alethea.Repo.Migrations.RemoveModelVersionFromEmotionAnalyses do
  use Ecto.Migration

  # Issue #198 — replace the development emotion analyzer behind the
  # established AI adapter seam. The legacy `model_version` column is no
  # longer set by any consumer (the worker dropped the hardcoded
  # "emotion-analyzer-v1" default) and the schema removed the field. Any
  # historical rows retained the column value but it is no longer
  # consulted by the runtime. Dropping the column aligns the persisted
  # shape with the development-only adapter contract.
  def change do
    alter table(:emotion_analyses) do
      remove :model_version
    end
  end
end

