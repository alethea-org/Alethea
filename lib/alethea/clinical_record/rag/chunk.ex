defmodule Alethea.ClinicalRecord.Rag.Chunk do
  @moduledoc """
  A retrievable slice of one eligible `ClinicalRecord` outbox event,
  backing the non-authoritative semantic projection
  (sdd/clinical-rag-projection, GitHub #196). Mirrors
  `Alethea.ClinicalRecord.ConsultationEvidence`: plaintext is never
  cast here — the indexer (WU2,
  `Alethea.ClinicalRecord.Rag.Indexer`) encrypts the source text under
  the patient's DEK via `Alethea.Encryption.PatientVault.encrypt/2`
  before calling `changeset/2`. The virtual `:content` field exists
  for the caller's convenience post-decryption and is `redact: true`
  so it never leaks through `inspect/1` or logs; `@derive` also
  excludes it explicitly.

  Unlike `ConsultationEvidence` (immutable, create-only), rows here
  ARE replaced in place on re-embed (design D4/D5: `replace_chunks/2`,
  WU2, deletes and re-inserts a resource's full chunk set in one
  transaction) — there is no immutability trigger, and `timestamps/1`
  below keeps `updated_at`.

  The uniqueness key (`source_resource_type`, `source_resource_id`,
  `chunk_index`) — one row per sub-chunk of a source resource — is
  enforced by the DB-level
  `clinical_record_rag_chunks_source_chunk_index` index (see the
  `create_clinical_record_rag_chunks` migration); `changeset/2`
  surfaces a violation through `unique_constraint/3`.

  `source_resource_id` has no FK, mirroring
  `ConsultationEvidence.source_id` (design A2 / this change's design
  section 1): the source is polymorphic across 5 `ClinicalRecord`
  tables, and a single `references/2` cannot express a union FK.

  `embedding` is `Pgvector.Ecto.Vector` (dep already present,
  `Alethea.PostgrexTypes` already registers the Postgrex extension) —
  not encrypted (design D9): it is a local-only numeric derivation
  never sent to an external API (ADR-002), and pgvector needs to
  compute `<=>` directly over this column.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:content]}
  schema "clinical_record_rag_chunks" do
    field :source_resource_type, :string
    field :source_resource_id, :binary_id
    field :chunk_index, :integer

    field :encrypted_content, :binary
    field :encryption_version, :integer, default: 1
    field :content, :string, virtual: true, redact: true

    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string
    field :token_count, :integer
    field :full_event, :boolean, default: true

    field :source_occurred_at, :utc_datetime_usec

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime)
  end

  @doc """
  Create/replace changeset. `:content` (plaintext) is intentionally
  NOT castable — only `:encrypted_content` is, mirroring
  `ConsultationEvidence.changeset/2`. `target_behavior_id` is the only
  optional foreign key (design D2 nullable filter facet); every other
  field is required.
  """
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :source_resource_type,
      :source_resource_id,
      :chunk_index,
      :encrypted_content,
      :encryption_version,
      :embedding,
      :embedding_model,
      :token_count,
      :full_event,
      :source_occurred_at,
      :patient_id,
      :professional_id,
      :target_behavior_id
    ])
    |> validate_required([
      :source_resource_type,
      :source_resource_id,
      :chunk_index,
      :encrypted_content,
      :embedding,
      :embedding_model,
      :token_count,
      :source_occurred_at,
      :patient_id,
      :professional_id
    ])
    |> unique_constraint(:chunk_index, name: :clinical_record_rag_chunks_source_chunk_index)
  end
end
