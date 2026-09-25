defmodule Alethea.Repo.Migrations.AddTranscriptMetadataToRagChunks do
  use Ecto.Migration

  # Adds nullable speaker/audio-time metadata to `clinical_record_rag_chunks`
  # for `:session_transcript` chunks (sdd/transcript-rag-ingestion-320,
  # GitHub #320, design AD8/D1/D3). `speaker` is plaintext by design (D3,
  # accepted deviation, #317 `audio_duration_seconds` precedent): a 2-value
  # role, not an identity, and #328 needs SQL filtering without decryption.
  #
  # `insert_all` bypasses `Chunk.changeset/2` (`Indexer.replace_chunks/2`),
  # so these three CHECK constraints are the only DB-level
  # guard — precedent: `consultation_evidences.source_kind_must_be_valid`
  # (20260831213217). Safe on existing data: no `session_transcript` chunk
  # can exist in any environment yet, because the `{:unknown, event}`
  # catch-all of `Indexer.eligibility/1` has always acknowledged those
  # events without indexing.
  def change do
    alter table(:clinical_record_rag_chunks) do
      add :speaker, :string
      add :audio_start_seconds, :float
      add :audio_end_seconds, :float
    end

    create constraint(:clinical_record_rag_chunks, :speaker_must_be_valid,
             check: "speaker IS NULL OR speaker IN ('patient', 'therapist')"
           )

    # Transcript chunks carry all three; every other kind carries none.
    create constraint(:clinical_record_rag_chunks, :transcript_metadata_consistent,
             check: """
             (source_resource_type = 'session_transcript') = (speaker IS NOT NULL)
             AND (speaker IS NULL) = (audio_start_seconds IS NULL)
             AND (speaker IS NULL) = (audio_end_seconds IS NULL)
             """
           )

    create constraint(:clinical_record_rag_chunks, :audio_bounds_ordered,
             check: "audio_start_seconds <= audio_end_seconds"
           )
  end
end
