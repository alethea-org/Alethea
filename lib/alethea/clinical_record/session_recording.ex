defmodule Alethea.ClinicalRecord.SessionRecording do
  @moduledoc """
  A recorded (or uploaded) therapy session on its way to becoming a
  `Alethea.ClinicalRecord.SessionTranscript` (session-recording S2/S3/S6).

  Lifecycle (`status`):

    * `"transcribing"` — the audio is stored encrypted and an
      `AletheaJobs.SessionTranscriptionWorker` job is pending.
    * `"needs_speakers"` — the provider returned two or more speakers; the
      diarized segments are stored encrypted until the professional says who
      is who. The audio is already gone.
    * `"ready"` — the transcript exists (`session_transcript_id`).
    * `"failed"` — `error_code` says why. Retry is possible only while the
      audio is still stored; once it is nulled, failure is final.

  Plaintext is never cast: `encrypted_audio` and `encrypted_segments` are
  ciphertext under the patient's clinical-record DEK, built by
  `Alethea.ClinicalRecord.SessionRecordings`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(transcribing needs_speakers ready failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:encrypted_audio, :encrypted_segments]}
  schema "session_recordings" do
    field :status, :string
    field :recorded_at, :utc_datetime_usec
    field :content_type, :string
    field :audio_duration_seconds, :integer
    field :encrypted_audio, :binary, redact: true
    field :encrypted_segments, :binary, redact: true
    field :error_code, :string
    field :consent_confirmed_at, :utc_datetime_usec

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :session_transcript, Alethea.ClinicalRecord.SessionTranscript

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Accepted `status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Create changeset. `patient_id` and `professional_id` are set on the struct
  by the context, never cast.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = recording, attrs) do
    recording
    |> cast(attrs, [:recorded_at, :content_type, :encrypted_audio, :consent_confirmed_at])
    |> put_change(:status, "transcribing")
    |> validate_required([
      :recorded_at,
      :content_type,
      :encrypted_audio,
      :consent_confirmed_at,
      :patient_id,
      :professional_id
    ])
    |> check_constraint(:status, name: :status_must_be_valid)
  end

  @doc "Status-transition changeset used by the context and the worker."
  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(%__MODULE__{} = recording, attrs) do
    recording
    |> cast(attrs, [
      :status,
      :encrypted_audio,
      :encrypted_segments,
      :audio_duration_seconds,
      :session_transcript_id,
      :error_code
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :status_must_be_valid)
  end
end
