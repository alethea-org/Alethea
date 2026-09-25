defmodule Alethea.Repo.Migrations.CreateSessionTranscripts do
  use Ecto.Migration

  # `session_transcripts` — one encrypted, speaker-attributed transcript per
  # recorded clinical session (sdd/session-transcript-317, GitHub #317).
  # NOT `clinical_sessions`, which is the patient Telegram journaling session.
  def change do
    create table(:session_transcripts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Sentinel + versioned positional JSON array of [start, end, speaker, text],
      # encrypted as ONE blob under the patient's clinical-record DEK (L2).
      add :encrypted_spans, :binary, null: false

      # Greenfield table: every write uses the CR-scoped DEK, so 2 — not the
      # sibling tables' 1, which exists only for their pre-#197 rows (AD3).
      add :encryption_version, :integer, null: false, default: 2

      # Plaintext by design (D1) — weak PII, enables session-time reporting
      # without decryption. Nullable: no audio producer exists yet (AD4).
      add :audio_duration_seconds, :integer

      # Required (D3): the therapist always knows the session date at creation.
      add :recorded_at, :utc_datetime_usec, null: false

      add :patient_id, references(:patients, on_delete: :delete_all, type: :binary_id),
        null: false

      # Professionals with authored clinical decisions cannot be hard-deleted,
      # mirroring consultation_evidences, target_behaviors, etc.
      add :professional_id, references(:professionals, on_delete: :restrict, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    # Serves patient-scoped listing (#320) AND, by leading-column prefix, every
    # patient-only scan (Retention sweeps, the patients FK cascade) — so no
    # separate [:patient_id] index is created (AD7).
    create index(:session_transcripts, [:patient_id, :recorded_at])
  end
end
