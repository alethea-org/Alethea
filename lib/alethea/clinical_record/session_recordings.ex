defmodule Alethea.ClinicalRecord.SessionRecordings do
  @moduledoc """
  Session-recording workflow behind `Alethea.ClinicalRecord`
  (session-recording S2/S3/S6).

  Every function here runs AFTER `Alethea.ClinicalRecord` authorized the
  professional for the patient and loaded the patient's keyring; callers go
  through the `Alethea.ClinicalRecord` public functions, never here directly.

  Encryption: audio and diarized segments are encrypted under the patient's
  clinical-record DEK, like `SessionTranscript`. Neither audio nor transcript
  text is ever logged; audit rows carry identifiers only.
  """

  require Logger

  import Ecto.Query

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{Audit, SessionRecording}
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias AletheaJobs.SessionTranscriptionWorker

  @segments_format "alethea.session-recording-segments"
  @segments_version 1
  @assignable_speakers ~w(patient therapist)

  @doc "PubSub topic carrying `{:session_recording_updated, recording_id}` per patient."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(patient_id), do: "session_recordings:#{patient_id}"

  @doc "Whether a failed recording can still be transcribed again (its audio is stored)."
  @spec retryable?(SessionRecording.t()) :: boolean()
  def retryable?(%SessionRecording{status: "failed", encrypted_audio: audio}),
    do: is_binary(audio)

  def retryable?(%SessionRecording{}), do: false

  # ── Create ────────────────────────────────────────────────────────────

  @doc false
  def create(professional, patient, keyring, attrs) do
    with :ok <- validate_consent(attrs),
         {:ok, audio} <- fetch_audio(attrs),
         {:ok, content_type} <- fetch_content_type(attrs),
         {:ok, ciphertext} <- PatientVault.encrypt(audio, keyring.clinical_record_dek) do
      now = DateTime.utc_now()

      changeset =
        %SessionRecording{patient_id: patient.id, professional_id: professional.id}
        |> SessionRecording.create_changeset(%{
          recorded_at: Map.get(attrs, :recorded_at) || now,
          content_type: content_type,
          encrypted_audio: ciphertext,
          consent_confirmed_at: now
        })

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:record, changeset)
      |> Ecto.Multi.insert(:audit, fn %{record: record} ->
        audit(professional.id, "session_recording_created", record.id)
      end)
      |> Oban.insert(:job, fn %{record: record} ->
        SessionTranscriptionWorker.new(%{"session_recording_id" => record.id})
      end)
      |> Repo.transaction()
      |> finalize()
    end
  end

  defp validate_consent(%{consent: true}), do: :ok
  defp validate_consent(_attrs), do: {:error, :consent_required}

  defp fetch_audio(%{audio: audio}) when is_binary(audio) and byte_size(audio) > 0,
    do: {:ok, audio}

  defp fetch_audio(_attrs), do: {:error, :empty_audio}

  defp fetch_content_type(%{content_type: type}) when is_binary(type) and type != "",
    do: {:ok, type}

  defp fetch_content_type(_attrs), do: {:error, :invalid_content_type}

  # ── Read ──────────────────────────────────────────────────────────────

  @doc false
  def list(patient) do
    SessionRecording
    |> where([r], r.patient_id == ^patient.id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  @doc false
  def fetch(patient, recording_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(recording_id),
         %SessionRecording{} = recording <-
           Repo.get_by(SessionRecording, id: uuid, patient_id: patient.id) do
      {:ok, recording}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def speaker_samples(%SessionRecording{status: "needs_speakers"} = recording, keyring) do
    with {:ok, segments} <- decrypt_segments(recording, keyring) do
      samples =
        segments
        |> Enum.reject(&(String.trim(&1.text) == ""))
        |> Enum.group_by(& &1.speaker)
        |> Enum.map(fn {speaker, speaker_segments} ->
          %{
            speaker: speaker,
            first_start: speaker_segments |> hd() |> Map.fetch!(:start),
            samples: speaker_segments |> Enum.take(2) |> Enum.map(&String.trim(&1.text))
          }
        end)
        |> Enum.sort_by(&{&1.first_start, &1.speaker})
        |> Enum.map(&Map.delete(&1, :first_start))

      {:ok, samples}
    end
  end

  def speaker_samples(%SessionRecording{}, _keyring), do: {:error, :invalid_status}

  # ── Speaker assignment ────────────────────────────────────────────────

  @doc false
  def assign_speakers(
        professional,
        patient,
        keyring,
        %SessionRecording{status: "needs_speakers"} = recording,
        mapping
      ) do
    with {:ok, segments} <- decrypt_segments(recording, keyring),
         {:ok, mapping} <- normalize_mapping(mapping),
         :ok <- validate_mapping(segments, mapping) do
      spans =
        segments
        |> Enum.reject(&(String.trim(&1.text) == ""))
        |> Enum.map(&%{&1 | speaker: Map.fetch!(mapping, &1.speaker)})

      Repo.transaction(fn ->
        with {:ok, transcript} <- create_transcript(professional, patient, recording, spans),
             {:ok, updated} <-
               recording
               |> SessionRecording.transition_changeset(%{
                 status: "ready",
                 session_transcript_id: transcript.id,
                 encrypted_segments: nil
               })
               |> Repo.update(),
             {:ok, _audit} <-
               Repo.insert(
                 audit(professional.id, "session_recording_speakers_assigned", recording.id)
               ) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_on_ok()
    end
  end

  def assign_speakers(_professional, _patient, _keyring, %SessionRecording{}, _mapping),
    do: {:error, :invalid_status}

  defp normalize_mapping(mapping) when is_map(mapping) do
    Enum.reduce_while(mapping, {:ok, %{}}, fn {key, role}, {:ok, acc} ->
      case normalize_speaker_key(key) do
        {:ok, speaker} -> {:cont, {:ok, Map.put(acc, speaker, role)}}
        :error -> {:halt, {:error, :invalid_speaker_mapping}}
      end
    end)
  end

  defp normalize_mapping(_mapping), do: {:error, :invalid_speaker_mapping}

  defp normalize_speaker_key(key) when is_integer(key) and key >= 0, do: {:ok, key}

  defp normalize_speaker_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {speaker, ""} when speaker >= 0 -> {:ok, speaker}
      _ -> :error
    end
  end

  defp normalize_speaker_key(_key), do: :error

  defp validate_mapping(segments, mapping) do
    speakers = segments |> Enum.map(& &1.speaker) |> MapSet.new()

    cond do
      MapSet.new(Map.keys(mapping)) != speakers -> {:error, :invalid_speaker_mapping}
      Enum.all?(Map.values(mapping), &(&1 in @assignable_speakers)) -> :ok
      true -> {:error, :invalid_speaker_mapping}
    end
  end

  # ── Retry ─────────────────────────────────────────────────────────────

  @doc false
  def retry(%SessionRecording{} = recording) do
    if retryable?(recording) do
      Ecto.Multi.new()
      |> Ecto.Multi.update(
        :record,
        SessionRecording.transition_changeset(recording, %{
          status: "transcribing",
          error_code: nil
        })
      )
      |> Oban.insert(:job, fn %{record: record} ->
        SessionTranscriptionWorker.new(%{"session_recording_id" => record.id})
      end)
      |> Repo.transaction()
      |> finalize()
    else
      {:error, :not_retryable}
    end
  end

  # ── Transcription (worker) ────────────────────────────────────────────

  @doc false
  def transcribe(professional, patient, keyring, recording, opts) do
    final_attempt? = Keyword.get(opts, :final_attempt?, false)

    with {:ok, audio} <- decrypt_audio(recording, keyring),
         {:ok, transcription} <- run_provider(audio, recording.content_type),
         {:ok, updated} <- complete(professional, patient, keyring, recording, transcription) do
      {:ok, updated}
    else
      {:error, :audio_unavailable} ->
        fail(professional, recording, "audio_unavailable")

      {:error, reason} ->
        if final_attempt? do
          fail(professional, recording, error_code(reason))
        else
          {:error, error_code(reason)}
        end
    end
  end

  defp run_provider(audio, content_type) do
    case Alethea.AI.whisper().transcribe(audio, content_type: content_type, language: "es") do
      {:ok, %{} = transcription} -> {:ok, transcription}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_response}
    end
  end

  defp complete(professional, patient, keyring, recording, transcription) do
    segments = normalize_segments(transcription)
    duration = duration_seconds(transcription, segments)

    distinct_speakers =
      segments |> Enum.map(& &1.speaker) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cond do
      segments == [] ->
        fail(professional, recording, "empty_transcript")

      length(distinct_speakers) >= 2 ->
        store_for_speaker_assignment(professional, keyring, recording, segments, duration)

      true ->
        spans = Enum.map(segments, &%{&1 | speaker: "unknown"})
        store_transcript(professional, patient, recording, spans, duration)
    end
  end

  defp store_for_speaker_assignment(professional, keyring, recording, segments, duration) do
    # A speaker-less segment inside a diarized result is attributed to the
    # previous speaker (or the first one), so every span can be mapped.
    segments = fill_missing_speakers(segments)

    with {:ok, ciphertext} <-
           PatientVault.encrypt(encode_segments(segments), keyring.clinical_record_dek) do
      Repo.transaction(fn ->
        with {:ok, updated} <-
               recording
               |> SessionRecording.transition_changeset(%{
                 status: "needs_speakers",
                 encrypted_segments: ciphertext,
                 encrypted_audio: nil,
                 audio_duration_seconds: duration,
                 error_code: nil
               })
               |> Repo.update(),
             {:ok, _audit} <-
               Repo.insert(audit(professional.id, "session_recording_transcribed", recording.id)) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_on_ok()
    end
  end

  defp store_transcript(professional, patient, recording, spans, duration) do
    recording = %{recording | audio_duration_seconds: duration}

    Repo.transaction(fn ->
      with {:ok, transcript} <- create_transcript(professional, patient, recording, spans),
           {:ok, updated} <-
             recording
             |> SessionRecording.transition_changeset(%{
               status: "ready",
               session_transcript_id: transcript.id,
               encrypted_audio: nil,
               audio_duration_seconds: duration,
               error_code: nil
             })
             |> Repo.update(),
           {:ok, _audit} <-
             Repo.insert(audit(professional.id, "session_recording_transcribed", recording.id)) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> broadcast_on_ok()
  end

  defp fail(professional, recording, code) do
    Logger.warning("session recording transcription failed: #{code}")

    Repo.transaction(fn ->
      with {:ok, updated} <-
             recording
             |> SessionRecording.transition_changeset(%{
               status: "failed",
               encrypted_audio: nil,
               error_code: code
             })
             |> Repo.update(),
           {:ok, _audit} <-
             Repo.insert(audit(professional.id, "session_recording_failed", recording.id)) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> broadcast_on_ok()
  end

  defp create_transcript(professional, patient, recording, spans) do
    ClinicalRecord.create_session_transcript(professional, patient.id, %{
      spans: spans,
      recorded_at: recording.recorded_at,
      audio_duration_seconds: recording.audio_duration_seconds
    })
  end

  # Never echoes provider payloads (they may carry transcript text).
  defp error_code(:disabled), do: "transcription_disabled"
  defp error_code(:timeout), do: "provider_timeout"
  defp error_code(%{__exception__: true}), do: "provider_error"
  defp error_code(_reason), do: "provider_error"

  # ── Segments ──────────────────────────────────────────────────────────

  defp normalize_segments(transcription) do
    segments =
      transcription
      |> Map.get(:segments, [])
      |> List.wrap()
      |> Enum.flat_map(&normalize_segment/1)

    case segments do
      [] -> text_only_segment(transcription)
      segments -> segments
    end
  end

  defp normalize_segment(%{start: start, end: stop, text: text} = segment)
       when is_number(start) and is_number(stop) and is_binary(text) do
    if String.trim(text) == "" do
      []
    else
      start = max(start, 0)

      [
        %{
          start: start,
          end: max(stop, start),
          speaker: speaker_index(Map.get(segment, :speaker)),
          text: String.trim(text)
        }
      ]
    end
  end

  defp normalize_segment(_segment), do: []

  defp speaker_index(speaker) when is_integer(speaker) and speaker >= 0, do: speaker
  defp speaker_index(_speaker), do: nil

  defp text_only_segment(transcription) do
    text = transcription |> Map.get(:text, "") |> to_string() |> String.trim()

    if text == "" do
      []
    else
      duration = Map.get(transcription, :duration)
      stop = if is_number(duration) and duration > 0, do: duration, else: 0
      [%{start: 0, end: stop, speaker: nil, text: text}]
    end
  end

  defp duration_seconds(transcription, segments) do
    case Map.get(transcription, :duration) do
      duration when is_number(duration) and duration >= 0 ->
        round(duration)

      _ ->
        segments |> Enum.map(& &1.end) |> Enum.max(fn -> 0 end) |> round()
    end
  end

  defp fill_missing_speakers([first | _] = segments) do
    default = Enum.find_value(segments, & &1.speaker) || first.speaker

    {filled, _last} =
      Enum.map_reduce(segments, default, fn segment, last ->
        speaker = segment.speaker || last
        {%{segment | speaker: speaker}, speaker}
      end)

    filled
  end

  defp encode_segments(segments) do
    Jason.encode!([
      @segments_format,
      @segments_version,
      Enum.map(segments, &[&1.start, &1.end, &1.speaker, &1.text])
    ])
  end

  defp decrypt_segments(%SessionRecording{encrypted_segments: nil}, _keyring),
    do: {:error, :segments_unavailable}

  defp decrypt_segments(%SessionRecording{encrypted_segments: ciphertext}, keyring) do
    with {:ok, plaintext} <- PatientVault.decrypt(ciphertext, keyring.clinical_record_dek),
         {:ok, [@segments_format, @segments_version, raw]} when is_list(raw) <-
           Jason.decode(plaintext),
         {:ok, segments} <- decode_segments(raw) do
      {:ok, segments}
    else
      _ -> {:error, :undecryptable}
    end
  end

  defp decode_segments(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn
      [start, stop, speaker, text], {:ok, acc}
      when is_number(start) and is_number(stop) and is_integer(speaker) and is_binary(text) ->
        {:cont, {:ok, [%{start: start, end: stop, speaker: speaker, text: text} | acc]}}

      _invalid, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      :error -> :error
    end
  end

  defp decrypt_audio(%SessionRecording{encrypted_audio: nil}, _keyring),
    do: {:error, :audio_unavailable}

  defp decrypt_audio(%SessionRecording{encrypted_audio: ciphertext}, keyring) do
    case PatientVault.decrypt(ciphertext, keyring.clinical_record_dek) do
      {:ok, audio} -> {:ok, audio}
      {:error, _reason} -> {:error, :audio_unavailable}
    end
  end

  # ── Shared ────────────────────────────────────────────────────────────

  defp audit(professional_id, action, recording_id) do
    Audit.changeset(%Audit{
      professional_id: professional_id,
      action: action,
      resource_type: "session_recording",
      resource_id: recording_id,
      outcome: "success"
    })
  end

  defp finalize(transaction_result) do
    case transaction_result do
      {:ok, %{record: record}} ->
        broadcast(record)
        {:ok, record}

      {:error, step, reason, _changes} ->
        Logger.warning("session recording multi failed at #{step}")
        {:error, reason}
    end
  end

  defp broadcast_on_ok({:ok, recording} = result) do
    broadcast(recording)
    result
  end

  defp broadcast_on_ok(error), do: error

  defp broadcast(%SessionRecording{id: id, patient_id: patient_id}) do
    Phoenix.PubSub.broadcast(
      Alethea.PubSub,
      topic(patient_id),
      {:session_recording_updated, id}
    )
  end
end
