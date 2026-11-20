defmodule Alethea.ClinicalRecord.SessionRecording do
  @moduledoc """
  A therapy session recorded in the browser on its way to becoming a
  `Alethea.ClinicalRecord.SessionTranscript` (session-recording S2/S3/S6/S7).

  Lifecycle (`status`):

    * `"recording"` — the browser is streaming audio; each piece is stored
      encrypted as a `Alethea.ClinicalRecord.SessionRecordingChunk`.
    * `"transcribing"` — recording finished (by the professional or by the
      cleanup job) and an `AletheaJobs.SessionTranscriptionWorker` job is
      pending.
    * `"needs_speakers"` — the provider returned two or more speakers; the
      diarized segments are stored encrypted until the professional says who
      is who. The audio chunks are already gone.
    * `"ready"` — the transcript exists (`session_transcript_id`).
    * `"failed"` — `error_code` says why. Retry is possible only while audio
      chunks are still stored; once they are deleted, failure is final.

  Plaintext is never cast: `encrypted_segments` is ciphertext under the
  patient's clinical-record DEK, built by
  `Alethea.ClinicalRecord.SessionRecordings`. `audio_stored?` is virtual and
  only filled by the context's read functions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(recording transcribing needs_speakers ready failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:encrypted_segments]}
  schema "session_recordings" do
    field :status, :string
    field :recorded_at, :utc_datetime_usec
    field :content_type, :string
    field :audio_duration_seconds, :integer
    field :encrypted_segments, :binary, redact: true
    field :error_code, :string
    field :consent_confirmed_at, :utc_datetime_usec
    field :audio_stored?, :boolean, virtual: true, default: false

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :session_transcript, Alethea.ClinicalRecord.SessionTranscript
    has_many :chunks, Alethea.ClinicalRecord.SessionRecordingChunk

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
    |> cast(attrs, [:recorded_at, :content_type, :consent_confirmed_at])
    |> put_change(:status, "recording")
    |> validate_required([
      :recorded_at,
      :content_type,
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
