defmodule Alethea.Repo.Migrations.CreateSessionRecordings do
  use Ecto.Migration

  # A therapy session recorded in the browser and streamed in chunks, then
  # transcribed (session-recording S2/S3/S6/S7). Each chunk in
  # `session_recording_chunks` holds ciphertext under the patient's
  # clinical-record DEK and is deleted once no longer needed: after
  # transcription, or after the final failed attempt. `encrypted_segments`
  # (also ciphertext) is nulled after the professional assigns speakers.
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
      add :encrypted_segments, :binary

      add :session_transcript_id,
          references(:session_transcripts, type: :binary_id, on_delete: :nilify_all)

      add :error_code, :string
      add :consent_confirmed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:session_recordings, :status_must_be_valid,
             check: "status IN ('recording', 'transcribing', 'needs_speakers', 'ready', 'failed')"
           )

    create index(:session_recordings, [:patient_id, :inserted_at])
    create index(:session_recordings, [:professional_id])
    create index(:session_recordings, [:session_transcript_id])
    create index(:session_recordings, [:status])

    create table(:session_recording_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_recording_id,
          references(:session_recordings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :seq, :integer, null: false
      add :encrypted_data, :binary, null: false
      add :byte_size, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:session_recording_chunks, [:session_recording_id, :seq])
  end
end
