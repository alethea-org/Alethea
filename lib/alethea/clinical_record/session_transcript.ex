defmodule Alethea.ClinicalRecord.SessionTranscript do
  @moduledoc """
  Encrypted, speaker-attributed transcript of one clinical session
  (sdd/session-transcript-317, GitHub #317).

  **Boundary note**: a `SessionTranscript` is NOT an `Alethea.Clinical.Session`.
  `Alethea.Clinical.Session` (table `clinical_sessions`) is a patient Telegram
  journaling session and carries no `professional_id`. This row belongs to the
  professional-authored clinical record: it is the transcript of a real
  therapy session (openspec/UBIQUITOUS_LANGUAGE.md: *Transcripción*).

  Plaintext is never cast here — the context serializes the spans through
  `Alethea.ClinicalRecord.SessionTranscriptContent` and encrypts them under the
  patient's clinical-record DEK before calling `changeset/2`, exactly as
  `Alethea.ClinicalRecord.FunctionalAnalysisDraft` does.

  `audio_duration_seconds` is a deliberate plaintext column (D1): duration alone
  is weak PII and session-time reporting must not require decrypting every row.
  This is a documented, accepted deviation from CLAUDE.md's "audio metadata"
  mandate.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, except: [:spans]}
  schema "session_transcripts" do
    field :encrypted_spans, :binary
    # Always 2 — greenfield table, every write uses the CR-scoped DEK (AD3).
    field :encryption_version, :integer, default: 2
    field :spans, {:array, :map}, virtual: true, redact: true

    # Plaintext by design (D1). Nullable until an audio producer exists (AD4).
    field :audio_duration_seconds, :integer
    field :recorded_at, :utc_datetime_usec

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  @doc """
  Create changeset. `:spans` (plaintext) is intentionally NOT castable —
  only `:encrypted_spans` is, mirroring `FunctionalAnalysisDraft.changeset/2`
  and `Rag.Chunk.changeset/2`. `audio_duration_seconds` is the only optional
  field (AD4).
  """
  def changeset(session_transcript, attrs) do
    session_transcript
    |> cast(attrs, [
      :encrypted_spans,
      :encryption_version,
      :audio_duration_seconds,
      :recorded_at,
      :patient_id,
      :professional_id
    ])
    |> validate_required([:encrypted_spans, :recorded_at, :patient_id, :professional_id])
  end
end
