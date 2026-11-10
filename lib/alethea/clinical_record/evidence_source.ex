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
  alias Alethea.ClinicalRecord.SessionTranscript
  alias Alethea.ClinicalRecord.SessionTranscriptContent
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
    :professional_id,
    :spans
  ]

  @type kind :: :clinical_note | :message | :session_transcript
  @type t :: %__MODULE__{
          kind: kind(),
          id: Ecto.UUID.t(),
          content: String.t(),
          occurred_at: DateTime.t(),
          direction: String.t() | nil,
          behavior_type: String.t() | nil,
          professional_id: Ecto.UUID.t() | nil,
          spans: [SessionTranscriptContent.span()] | nil
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

  @default_page_size 20

  @typedoc """
  Keyset cursor for `list_page/3`: `{priority, occurred_at, id}` of the last
  source already shown. Priority 0 is an inbound message; 1 is anything else.
  """
  @type cursor :: {0 | 1, DateTime.t(), Ecto.UUID.t()}

  @doc """
  Lists one page of eligible sources in exactly the `list/2` order (inbound
  messages first, then outbound messages and clinical notes; each group newest
  first, ties broken by ascending id), decrypting only the returned page.

  Options: `:limit` (default #{@default_page_size}) and `:before`, a
  `t:cursor/0` (see `cursor/1`) — only sources after it in that order are
  returned. Returns `{:ok, %{entries: [t()], has_more?: boolean()}}`.
  """
  @spec list_page(Ecto.UUID.t(), keyring(), keyword()) ::
          {:ok, %{entries: [t()], has_more?: boolean()}} | {:error, term()}
  def list_page(patient_id, keyring, opts) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    cursor = Keyword.get(opts, :before)

    # Each query fetches at most limit + 1 rows past the cursor; merging and
    # taking limit + 1 then yields the page plus a "more exist" probe.
    inbound =
      if inbound_pending?(cursor) do
        Journaling.Message
        |> where([m], m.patient_id == ^patient_id and m.direction == "inbound")
        |> after_cursor(cursor, 0, :timestamp)
        |> page_query(:timestamp, limit)
        |> Repo.all()
        |> Enum.map(&{:message, &1, 0, &1.timestamp})
      else
        []
      end

    rest =
      if length(inbound) > limit do
        []
      else
        outbound =
          Journaling.Message
          |> where(
            [m],
            m.patient_id == ^patient_id and (is_nil(m.direction) or m.direction != "inbound")
          )
          |> after_cursor(cursor, 1, :timestamp)
          |> page_query(:timestamp, limit)
          |> Repo.all()
          |> Enum.map(&{:message, &1, 1, &1.timestamp})

        notes =
          ClinicalNote
          |> where([n], n.patient_id == ^patient_id)
          |> after_cursor(cursor, 1, :inserted_at)
          |> page_query(:inserted_at, limit)
          |> Repo.all()
          |> Enum.map(&{:clinical_note, &1, 1, &1.inserted_at})

        Enum.sort_by(outbound ++ notes, fn {_kind, row, _priority, at} ->
          {-DateTime.to_unix(utc_datetime(at), :microsecond), row.id}
        end)
      end

    {page, probe} = Enum.split(Enum.take(inbound ++ rest, limit + 1), limit)

    with {:ok, sources} <- decrypt_all(page, &decrypt_row(&1, keyring)) do
      {:ok, %{entries: Enum.reverse(sources), has_more?: probe != []}}
    end
  end

  @doc "Returns the `list_page/3` cursor that continues after `source`."
  @spec cursor(t()) :: cursor()
  def cursor(%__MODULE__{} = source) do
    {priority, _negated_at, id} = sort_key(source)
    {priority, source.occurred_at, id}
  end

  defp inbound_pending?(nil), do: true
  defp inbound_pending?({priority, _at, _id}), do: priority == 0

  # Rows of `priority` strictly after the cursor in (occurred_at desc, id asc)
  # order. A cursor in an earlier priority group leaves this group unfiltered.
  defp after_cursor(query, {priority, at, id}, priority, field) do
    where(
      query,
      [r],
      field(r, ^field) < ^at or (field(r, ^field) == ^at and r.id > ^id)
    )
  end

  defp after_cursor(query, _cursor, _priority, _field), do: query

  defp page_query(query, field, limit) do
    query
    |> order_by([r], desc: field(r, ^field), asc: r.id)
    |> limit(^(limit + 1))
  end

  defp decrypt_row({:message, row, _priority, _at}, keyring), do: from_message(row, keyring)
  defp decrypt_row({:clinical_note, row, _priority, _at}, keyring), do: from_note(row, keyring)

  @doc """
  Re-fetches one eligible source under the owning patient. Unsupported kinds
  and missing, malformed, or foreign ids are rejected without exposing rows.
  """
  @spec fetch(String.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyring()) ::
          {:ok, t()} | {:error, :unsupported_source | :not_found | term()}
  def fetch(kind, source_id, patient_id, keyring)

  def fetch(kind, _source_id, _patient_id, _keyring)
      when kind not in ["clinical_note", "message", "session_transcript"],
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

  defp fetch_owned("session_transcript", id, patient_id) do
    case Repo.get_by(SessionTranscript, id: id, patient_id: patient_id) do
      nil -> {:error, :not_found}
      transcript -> {:ok, transcript}
    end
  end

  defp decrypt_source("clinical_note", note, keyring), do: from_note(note, keyring)
  defp decrypt_source("message", message, keyring), do: from_message(message, keyring)

  defp decrypt_source("session_transcript", transcript, keyring),
    do: from_session_transcript(transcript, keyring)

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

  defp from_session_transcript(transcript, keyring) do
    with {:ok, plaintext} <-
           PatientVault.decrypt(
             transcript.encrypted_spans,
             dek_for(transcript.encryption_version, keyring)
           ),
         {:ok, %SessionTranscriptContent{spans: spans}} <-
           SessionTranscriptContent.parse(plaintext) do
      {:ok,
       %__MODULE__{
         kind: :session_transcript,
         id: transcript.id,
         content: Enum.map_join(spans, "\n", & &1.text),
         occurred_at: utc_datetime(transcript.recorded_at),
         spans: spans
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
