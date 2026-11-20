defmodule Alethea.Repo.Migrations.CreateSessionRecordings do
  use Ecto.Migration

  # A recorded (or uploaded) therapy session awaiting or done with
  # transcription (session-recording S2/S3/S6). `encrypted_audio` and
  # `encrypted_segments` hold ciphertext under the patient's clinical-record
  # DEK and are nulled once they are no longer needed: audio after
  # transcription (or the final failed attempt), segments after the
  # professional assigns speakers.
  def change do
    create table(:session_recordings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :patient_id, references(:patients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :professional_id, references(:professionals, type: :binary_id, on_delete: :restrict),
        null: false

      add :status, :string, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      add :content_type, :string, null: false
      add :audio_duration_seconds, :integer
      add :encrypted_audio, :binary
      add :encrypted_segments, :binary

      add :session_transcript_id,
          references(:session_transcripts, type: :binary_id, on_delete: :nilify_all)

      add :error_code, :string
      add :consent_confirmed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:session_recordings, :status_must_be_valid,
             check: "status IN ('transcribing', 'needs_speakers', 'ready', 'failed')"
           )

    create index(:session_recordings, [:patient_id, :inserted_at])
    create index(:session_recordings, [:professional_id])
    create index(:session_recordings, [:session_transcript_id])
  end
end
