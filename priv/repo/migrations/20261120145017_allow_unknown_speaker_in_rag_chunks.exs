defmodule Alethea.Repo.Migrations.AllowUnknownSpeakerInRagChunks do
  use Ecto.Migration

  # Session recordings whose provider returned no (or a single) speaker store
  # their spans with speaker "unknown" (session-recording S3), so transcript
  # chunks may carry it too. Recreates the CHECK from 20260925183413.
  def up do
    drop constraint(:clinical_record_rag_chunks, :speaker_must_be_valid)

    create constraint(:clinical_record_rag_chunks, :speaker_must_be_valid,
             check: "speaker IS NULL OR speaker IN ('patient', 'therapist', 'unknown')"
           )
  end

  def down do
    drop constraint(:clinical_record_rag_chunks, :speaker_must_be_valid)

    create constraint(:clinical_record_rag_chunks, :speaker_must_be_valid,
             check: "speaker IS NULL OR speaker IN ('patient', 'therapist')"
           )
  end
end
