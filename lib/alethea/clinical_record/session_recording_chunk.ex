defmodule Alethea.ClinicalRecord.SessionRecordingChunk do
  @moduledoc """
  One streamed piece of a `Alethea.ClinicalRecord.SessionRecording`
  (session-recording S2/S7).

  The browser's MediaRecorder emits a chunk about every 10 seconds; each one
  is stored as soon as it arrives, so a closed tab or a lost connection keeps
  what was already sent. Concatenating the decrypted chunks ordered by `seq`
  rebuilds the recorded file. `encrypted_data` is ciphertext under the
  patient's clinical-record DEK; `byte_size` is the plaintext size, used for
  the per-recording limit. Chunks are deleted after transcription and after
  the final failed attempt.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:encrypted_data]}
  schema "session_recording_chunks" do
    field :seq, :integer
    field :encrypted_data, :binary, redact: true
    field :byte_size, :integer

    belongs_to :session_recording, Alethea.ClinicalRecord.SessionRecording

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
