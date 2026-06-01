defmodule Alethea.Repo.Migrations.CreateEmotionAnalyses do
  use Ecto.Migration

  def change do
    create table(:emotion_analyses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, on_delete: :delete_all, type: :binary_id),
        null: false

      add :model_version, :string, null: false, default: "robertuito-emotion-analysis"

      add :joy_score, :float
      add :sadness_score, :float
      add :anger_score, :float
      add :fear_score, :float
      add :neutral_score, :float

      add :dominant_label, :string
      add :confidence, :float

      add :processed_at, :utc_datetime, default: fragment("NOW()")

      timestamps(type: :utc_datetime)
    end

    create index(:emotion_analyses, [:message_id])
    create index(:emotion_analyses, [:processed_at])
    create index(:emotion_analyses, [:dominant_label])
  end
end
