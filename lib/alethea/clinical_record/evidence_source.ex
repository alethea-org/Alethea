defmodule Alethea.ClinicalRecord.EvidenceSource do
  @moduledoc """
  Read-only adapter for patient-owned sources that may be cited as consultation
  evidence.

  This is the only ClinicalRecord module that reads journaling messages. It
  scopes every lookup by patient id and returns authoritative decrypted content
  plus the provenance metadata needed by the citation UI.
  """

  import Ecto.Query

  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord.ClinicalNote
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  @enforce_keys [:kind, :id, :content, :occurred_at]
  defstruct [
    :kind,
    :id,
    :content,
    :occurred_at,
    :direction,
    :behavior_type,
    :professional_id
  ]

  @type kind :: :clinical_note | :message
  @type t :: %__MODULE__{
          kind: kind(),
          id: Ecto.UUID.t(),
          content: String.t(),
          occurred_at: DateTime.t(),
          direction: String.t() | nil,
          behavior_type: String.t() | nil,
          professional_id: Ecto.UUID.t() | nil
        }
  @type keyring :: %{patient_dek: binary(), clinical_record_dek: binary()}

  @doc """
  Lists all eligible patient-owned sources. Inbound messages are presented
  first; each priority group is reverse chronological and deterministic.
  """
  @spec list(Ecto.UUID.t(), keyring()) :: {:ok, [t()]} | {:error, term()}
  def list(patient_id, keyring) do
    notes =
      ClinicalNote
      |> where([note], note.patient_id == ^patient_id)
      |> Repo.all()

    messages =
      Journaling.Message
      |> where([message], message.patient_id == ^patient_id)
      |> Repo.all()

    with {:ok, note_sources} <- decrypt_all(notes, &from_note(&1, keyring)),
         {:ok, message_sources} <- decrypt_all(messages, &from_message(&1, keyring)) do
      {:ok, Enum.sort_by(message_sources ++ note_sources, &sort_key/1)}
    end
  end

  @doc """
  Re-fetches one eligible source under the owning patient. Unsupported kinds
  and missing, malformed, or foreign ids are rejected without exposing rows.
  """
  @spec fetch(String.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyring()) ::
          {:ok, t()} | {:error, :unsupported_source | :not_found | term()}
  def fetch(kind, source_id, patient_id, keyring)

  def fetch(kind, _source_id, _patient_id, _keyring)
      when kind not in ["clinical_note", "message"],
      do: {:error, :unsupported_source}

  def fetch(kind, source_id, patient_id, keyring) do
    with {:ok, id} <- cast_id(source_id),
         {:ok, source} <- fetch_owned(kind, id, patient_id),
         {:ok, evidence_source} <- decrypt_source(kind, source, keyring) do
      {:ok, evidence_source}
    end
  end

  defp cast_id(source_id) do
    case Ecto.UUID.cast(source_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp fetch_owned("clinical_note", id, patient_id) do
    case Repo.get_by(ClinicalNote, id: id, patient_id: patient_id) do
      nil -> {:error, :not_found}
      note -> {:ok, note}
    end
  end

  defp fetch_owned("message", id, patient_id) do
    case Repo.get_by(Journaling.Message, id: id, patient_id: patient_id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  defp decrypt_source("clinical_note", note, keyring), do: from_note(note, keyring)
  defp decrypt_source("message", message, keyring), do: from_message(message, keyring)

  defp from_note(note, keyring) do
    with {:ok, content} <-
           PatientVault.decrypt(note.encrypted_body, dek_for(note.encryption_version, keyring)) do
      {:ok,
       %__MODULE__{
         kind: :clinical_note,
         id: note.id,
         content: content,
         occurred_at: utc_datetime(note.inserted_at),
         professional_id: note.professional_id
       }}
    end
  end

  defp from_message(message, keyring) do
    with {:ok, content} <-
           PatientVault.decrypt(
             message.encrypted_content,
             dek_for(message.encryption_version, keyring)
           ) do
      {:ok,
       %__MODULE__{
         kind: :message,
         id: message.id,
         content: content,
         occurred_at: utc_datetime(message.timestamp),
         direction: message.direction,
         behavior_type: message.behavior_type
       }}
    end
  end

  defp decrypt_all(rows, decrypt) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, sources} ->
      case decrypt.(row) do
        {:ok, source} -> {:cont, {:ok, [source | sources]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sort_key(%__MODULE__{} = source) do
    priority = if source.kind == :message and source.direction == "inbound", do: 0, else: 1
    {priority, -DateTime.to_unix(source.occurred_at, :microsecond), source.id}
  end

  defp dek_for(1, keyring), do: keyring.patient_dek
  defp dek_for(2, keyring), do: keyring.clinical_record_dek

  defp utc_datetime(%DateTime{} = datetime), do: datetime
  defp utc_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")
end
