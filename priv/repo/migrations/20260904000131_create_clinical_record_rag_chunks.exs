defmodule Alethea.Repo.Migrations.CreateClinicalRecordRagChunks do
  use Ecto.Migration

  # `clinical_record_rag_chunks` backs the non-authoritative semantic
  # projection of `ClinicalRecord` (sdd/clinical-rag-projection, GitHub
  # #196, WU1 — see design.md sections 1/2). Rows here are a derived,
  # replaceable index — never the source of truth (D4/D5: replace-on-
  # re-embed deletes and re-inserts a resource's full chunk set inside
  # one transaction, so this table is never treated as immutable).
  #
  # Independent of `20260526141108_add_sessions_and_embeddings.exs`:
  # that migration only ever left a comment describing a deferred
  # `vector(384)` column on `messages` — it never executed, no column
  # exists — so there is nothing to subsume or migrate away from here.
  #
  # `CREATE EXTENSION IF NOT EXISTS vector` has a no-op `down`: rollback
  # of this migration must not drop the extension (other pgvector
  # consumers may depend on it staying installed; it is inert with no
  # tables referencing it once this migration is rolled back).
  def change do
    execute("CREATE EXTENSION IF NOT EXISTS vector", "")

    create table(:clinical_record_rag_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Professionals with authored clinical records cannot be
      # hard-deleted — authorship must survive, mirroring
      # `target_behaviors`/`consultation_evidences`.
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      # No FK on purpose (design section 1, mirrors
      # `ConsultationEvidence.source_id` / design A2): the source
      # resource is polymorphic across 5 `ClinicalRecord` tables
      # (ClinicalNote, ConsultationEvidence, ClinicianObservation,
      # AIProposal, FunctionalAnalysisDraft), and a cross-table FK
      # would need a CHECK-style union no single `references/2` call
      # can express.
      add :source_resource_type, :string, null: false
      add :source_resource_id, :binary_id, null: false
      add :chunk_index, :integer, null: false

      add :encrypted_content, :binary, null: false
      add :encryption_version, :integer, null: false, default: 1

      # Not encrypted (design section 1 / D9): embeddings are a local-
      # only numeric derivation, never sent to an external API — see
      # ADR-002 — and pgvector needs to compute `<=>` directly over
      # this column, which an opaque ciphertext blob would prevent.
      add :embedding, :vector, size: 1024, null: false
      add :embedding_model, :string, null: false
      add :token_count, :integer, null: false

      add :full_event, :boolean, null: false, default: true

      # Nullable filter facet (design D2): a chunk may cite the
      # target behavior it is evidence for, but most source resources
      # (e.g. an AIProposal) may not resolve to exactly one. Nilify
      # (not cascade-delete) on target_behavior removal — the chunk
      # itself remains valid evidence, just loses the facet.
      add :target_behavior_id,
          references(:target_behaviors, on_delete: :nilify_all, type: :binary_id)

      add :source_occurred_at, :utc_datetime_usec, null: false

      # `updated_at` is kept (unlike the immutable `ConsultationEvidence`/
      # `ClinicalNote` rows): a resource's chunk set is replaced in
      # place on re-embed (D4/D5), so rows here are mutated, not
      # append-only.
      timestamps(type: :utc_datetime)
    end

    # D3 key: one chunk set per source resource, addressed by index —
    # `replace_chunks/2` (indexer, WU2) relies on this to converge
    # idempotently under retry (delete-by-resource then insert_all,
    # racing concurrent runs into a unique-index violation instead of
    # duplicate rows).
    create unique_index(
             :clinical_record_rag_chunks,
             [:source_resource_type, :source_resource_id, :chunk_index],
             name: :clinical_record_rag_chunks_source_chunk_index
           )

    create index(:clinical_record_rag_chunks, [:patient_id])

    # HNSW over IVFFlat (design section 1 — resolves the deferred
    # sizing risk): IVFFlat's `lists` parameter must be tuned against a
    # populated table, but this migration runs before any data exists,
    # which would produce degenerate clusters needing a later rebuild.
    # HNSW builds correctly on an empty table and degrades gracefully
    # as rows arrive; `m = 16, ef_construction = 64` are pgvector's
    # documented defaults, kept implicit rather than pinned so a future
    # tuning pass does not need a migration. Raw SQL because
    # `create index/3` has no built-in operator-class support.
    execute(
      "CREATE INDEX clinical_record_rag_chunks_embedding_hnsw_idx ON clinical_record_rag_chunks USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS clinical_record_rag_chunks_embedding_hnsw_idx"
    )
  end
end
