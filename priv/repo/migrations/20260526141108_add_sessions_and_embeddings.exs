defmodule Alethea.Repo.Migrations.AddSessionsAndEmbeddings do
  use Ecto.Migration

  def change do
    # pgvector extension + embedding column require pgvector installed on the PG server.
    # The embedding column is deferred (no code fills it in this issue).
    # Run this block manually once pgvector is available:
    #   CREATE EXTENSION IF NOT EXISTS vector;
    #   ALTER TABLE messages ADD COLUMN embedding vector(384);
    #
    # STALE (sdd/clinical-rag-projection, GitHub #196, design.md
    # section 1, D7): this block never ran — comment-only, no column
    # was ever added to `messages`. The real embedding column for the
    # RAG projection lives on `clinical_record_rag_chunks.embedding`,
    # `vector(1024)` (matching BGE-M3, ADR-002 revised), created by
    # `20260904000131_create_clinical_record_rag_chunks.exs`. This
    # comment is left as-is (annotated, not deleted) since Ecto does
    # not checksum migration bodies and this migration already ran;
    # `messages` still has no `embedding` column and none is planned.

    create table(:clinical_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :started_at, :utc_datetime, null: false
      add :closed_at, :utc_datetime
      add :status, :string, null: false, default: "open"
      timestamps(type: :utc_datetime)
    end

    create index(:clinical_sessions, [:patient_id, :status])

    alter table(:messages) do
      add :session_id, references(:clinical_sessions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:messages, [:session_id])

    alter table(:clinical_summaries) do
      add :type, :string, null: false, default: "session"
    end

    alter table(:patients) do
      add :session_day_of_week, :integer
      add :session_time, :time
    end
  end
end
