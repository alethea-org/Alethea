defmodule Alethea.Repo.Migrations.AddAudioMarkersToConsultationEvidences do
  use Ecto.Migration

  # Widens `consultation_evidences.source_kind` to accept `session_transcript`
  # and adds nullable plaintext audio markers (speaker/start/end) snapshotted
  # at citation time (sdd/audio-evidence-citation-328, GitHub #328, design
  # AD1/AD9). Nullable ADD COLUMN and ADD CONSTRAINT never fire the
  # `consultation_evidences_no_update` BEFORE UPDATE trigger
  # (20260831213217:64-68) — that trigger only fires on row UPDATE DML, and
  # neither of these operations updates any existing row.
  #
  # `up`/`down` (not `change`) because dropping and recreating a named CHECK
  # constraint is not automatically reversible.
  def up do
    drop constraint(:consultation_evidences, :source_kind_must_be_valid)

    create constraint(:consultation_evidences, :source_kind_must_be_valid,
             check: "source_kind IN ('clinical_note', 'message', 'session_transcript')"
           )

    alter table(:consultation_evidences) do
      add :speaker, :string
      add :audio_start_seconds, :float
      add :audio_end_seconds, :float
    end

    # AD9's DB-level analog: a session_transcript row always carries all
    # three markers together; every other kind carries none.
    create constraint(:consultation_evidences, :audio_markers_shape,
             check: """
             (source_kind = 'session_transcript') = (speaker IS NOT NULL)
             AND (speaker IS NULL) = (audio_start_seconds IS NULL)
             AND (speaker IS NULL) = (audio_end_seconds IS NULL)
             """
           )
  end

  # Fails if any `session_transcript` row exists — those rows must be
  # deleted first (proposal rollback note).
  def down do
    drop constraint(:consultation_evidences, :audio_markers_shape)

    alter table(:consultation_evidences) do
      remove :speaker
      remove :audio_start_seconds
      remove :audio_end_seconds
    end

    drop constraint(:consultation_evidences, :source_kind_must_be_valid)

    create constraint(:consultation_evidences, :source_kind_must_be_valid,
             check: "source_kind IN ('clinical_note', 'message')"
           )
  end
end
