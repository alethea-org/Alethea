defmodule Alethea.ClinicalRecord.SessionRecordings do
  @moduledoc """
  Session-recording workflow behind `Alethea.ClinicalRecord`
  (session-recording S2/S3/S6).

  Every function here runs AFTER `Alethea.ClinicalRecord` authorized the
  professional for the patient and loaded the patient's keyring; callers go
  through the `Alethea.ClinicalRecord` public functions, never here directly.

  Encryption: audio chunks and diarized segments are encrypted under the
  patient's clinical-record DEK, like `SessionTranscript`. Neither audio nor transcript
  text is ever logged; audit rows carry identifiers only.
  """

  require Logger

  import Ecto.Query

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{Audit, SessionRecording, SessionRecordingChunk}
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias AletheaJobs.SessionTranscriptionWorker

  @segments_format "alethea.session-recording-segments"
  @segments_version 1
  @assignable_speakers ~w(patient therapist)

  # MediaRecorder output: Opus in WebM (Chrome, Firefox) or MP4 (Safari).
  @content_types ~w(audio/webm audio/mp4)
  @max_chunk_bytes 512 * 1024
  # Four hours of ~10 s chunks, with headroom for uneven timeslices.
  @max_chunks 1_600
  # Four hours at ~24 kbps is ~45 MB.
  @max_recording_bytes 60_000_000
  @live_job_states ~w(available scheduled executing retryable)

  @doc "PubSub topic carrying `{:session_recording_updated, recording_id}` per patient."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(patient_id), do: "session_recordings:#{patient_id}"

  @doc "Whether a failed recording can still be transcribed again (its audio chunks are stored)."
  @spec retryable?(SessionRecording.t()) :: boolean()
  def retryable?(%SessionRecording{status: "failed", audio_stored?: stored?}), do: stored?
  def retryable?(%SessionRecording{}), do: false

  @doc "Largest accepted chunk, in bytes (plaintext)."
  def max_chunk_bytes, do: @max_chunk_bytes

  # ── Start ─────────────────────────────────────────────────────────────

  @doc false
  def start(professional, patient, attrs) do
    with :ok <- validate_consent(attrs),
         {:ok, content_type} <- fetch_content_type(attrs) do
      now = DateTime.utc_now()

      changeset =
        %SessionRecording{patient_id: patient.id, professional_id: professional.id}
        |> SessionRecording.create_changeset(%{
          recorded_at: now,
          content_type: content_type,
          consent_confirmed_at: now
        })

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:record, changeset)
      |> Ecto.Multi.insert(:audit, fn %{record: record} ->
        audit(professional.id, "session_recording_created", record.id)
      end)
      |> Repo.transaction()
      |> finalize()
    end
  end

  defp validate_consent(%{consent: true}), do: :ok
  defp validate_consent(_attrs), do: {:error, :consent_required}

  # MediaRecorder reports e.g. `audio/webm;codecs=opus`; only the base type
  # decides, the parameters are kept for the provider.
  defp fetch_content_type(%{content_type: type}) when is_binary(type) do
    base = type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    if base in @content_types and byte_size(type) <= 100,
      do: {:ok, String.trim(type)},
      else: {:error, :invalid_content_type}
  end

  defp fetch_content_type(_attrs), do: {:error, :invalid_content_type}

  # ── Chunks ────────────────────────────────────────────────────────────

  @doc false
  def append_chunk(patient, keyring, recording_id, seq, data) do
    with :ok <- validate_chunk(seq, data),
         {:ok, uuid} <- cast_id(recording_id),
         {:ok, ciphertext} <- PatientVault.encrypt(data, keyring.clinical_record_dek) do
      # FOR SHARE: appends never block each other but wait for (and then see)
      # a concurrent finish, which locks the row FOR UPDATE.
      Repo.transaction(fn ->
        with {:ok, _recording} <- lock_recording(uuid, patient.id),
             :ok <- validate_total_size(uuid, byte_size(data)) do
          Repo.insert_all(
            SessionRecordingChunk,
            [
              %{
                id: Ecto.UUID.generate(),
                session_recording_id: uuid,
                seq: seq,
                encrypted_data: ciphertext,
                byte_size: byte_size(data),
                inserted_at: DateTime.utc_now()
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:session_recording_id, :seq]
          )

          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_chunk(seq, _data) when not is_integer(seq) or seq < 0,
    do: {:error, :invalid_chunk}

  defp validate_chunk(_seq, data) when not is_binary(data) or byte_size(data) == 0,
    do: {:error, :invalid_chunk}

  defp validate_chunk(_seq, data) when byte_size(data) > @max_chunk_bytes,
    do: {:error, :chunk_too_large}

  defp validate_chunk(seq, _data) when seq >= @max_chunks, do: {:error, :recording_too_long}
  defp validate_chunk(_seq, _data), do: :ok

  defp validate_total_size(recording_id, incoming) do
    stored =
      SessionRecordingChunk
      |> where([c], c.session_recording_id == ^recording_id)
      |> select([c], coalesce(sum(c.byte_size), 0))
      |> Repo.one()

    if stored + incoming > @max_recording_bytes,
      do: {:error, :recording_too_long},
      else: :ok
  end

  defp lock_recording(id, patient_id) do
    SessionRecording
    |> where([r], r.id == ^id and r.patient_id == ^patient_id)
    |> lock("FOR SHARE")
    |> Repo.one()
    |> case do
      %SessionRecording{status: "recording"} = recording -> {:ok, recording}
      %SessionRecording{} -> {:error, :not_recording}
      nil -> {:error, :not_found}
    end
  end

  # ── Finish ────────────────────────────────────────────────────────────

  @doc false
  def finish(professional, %SessionRecording{} = recording) do
    Repo.transaction(fn ->
      with {:ok, recording} <- lock_in_status(recording.id, "recording"),
           {:ok, updated} <- close_recording(professional.id, recording) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> broadcast_on_ok()
  end

  # Must run inside a transaction holding the row lock. With audio the
  # recording moves on to transcription (job enqueued in the same
  # transaction); without any chunk it fails as `empty_recording`.
  defp close_recording(professional_id, recording) do
    if chunks_stored?(recording.id) do
      with {:ok, updated} <-
             recording
             |> SessionRecording.transition_changeset(%{status: "transcribing", error_code: nil})
             |> Repo.update(),
           {:ok, _job} <-
             Oban.insert(SessionTranscriptionWorker.new(%{"session_recording_id" => updated.id})) do
        {:ok, %{updated | audio_stored?: true}}
      end
    else
      mark_failed(professional_id, recording, "empty_recording")
    end
  end

  # ── Cleanup (cron) ────────────────────────────────────────────────────

  @doc false
  def clean_up(now, abandoned_after_seconds, stalled_after_seconds) do
    abandoned_cutoff = DateTime.add(now, -abandoned_after_seconds, :second)

    stalled_cutoff =
      now |> DateTime.add(-stalled_after_seconds, :second) |> DateTime.truncate(:second)

    finalized =
      abandoned_cutoff
      |> abandoned_recording_ids()
      |> Enum.count(&match?({:ok, _}, finalize_abandoned(&1, abandoned_cutoff)))

    failed =
      stalled_cutoff
      |> stalled_recording_ids()
      |> Enum.count(&match?({:ok, _}, fail_stalled(&1, stalled_cutoff)))

    %{finalized: finalized, stalled: failed}
  end

  defp last_activity_query do
    last_chunk =
      SessionRecordingChunk
      |> group_by([c], c.session_recording_id)
      |> select([c], %{id: c.session_recording_id, last_at: max(c.inserted_at)})

    from r in SessionRecording,
      left_join: c in subquery(last_chunk),
      on: c.id == r.id,
      where: r.status == "recording"
  end

  defp abandoned_recording_ids(cutoff) do
    last_activity_query()
    |> where([r, c], coalesce(c.last_at, r.recorded_at) < ^cutoff)
    |> select([r], r.id)
    |> Repo.all()
  end

  defp finalize_abandoned(id, cutoff) do
    Repo.transaction(fn ->
      with {:ok, recording} <- lock_in_status(id, "recording"),
           true <- still_abandoned?(id, cutoff) || {:error, :active},
           {:ok, updated} <- close_recording(recording.professional_id, recording) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> broadcast_on_ok()
  end

  defp still_abandoned?(id, cutoff) do
    last_activity_query()
    |> where([r, c], r.id == ^id and coalesce(c.last_at, r.recorded_at) < ^cutoff)
    |> Repo.exists?()
  end

  defp stalled_recording_ids(cutoff) do
    SessionRecording
    |> where([r], r.status == "transcribing" and r.updated_at < ^cutoff)
    |> select([r], r.id)
    |> Repo.all()
    |> Enum.reject(&transcription_job_alive?/1)
  end

  defp fail_stalled(id, cutoff) do
    Repo.transaction(fn ->
      with {:ok, recording} <- lock_in_status(id, "transcribing"),
           true <- DateTime.compare(recording.updated_at, cutoff) == :lt || {:error, :active},
           :ok <- if(transcription_job_alive?(id), do: {:error, :active}, else: :ok),
           {:ok, updated} <- mark_failed(recording.professional_id, recording, "stalled") do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> log_failure_on_ok("stalled")
    |> broadcast_on_ok()
  end

  defp transcription_job_alive?(recording_id) do
    worker = inspect(SessionTranscriptionWorker)

    Oban.Job
    |> where([j], j.worker == ^worker and j.state in ^@live_job_states)
    |> where([j], fragment("?->>'session_recording_id' = ?", j.args, ^recording_id))
    |> Repo.exists?()
  end

  # ── Read ──────────────────────────────────────────────────────────────

  @doc false
  def list(patient) do
    SessionRecording
    |> where([r], r.patient_id == ^patient.id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> with_audio_stored()
    |> Repo.all()
  end

  @doc false
  def fetch(patient, recording_id) do
    with {:ok, uuid} <- cast_id(recording_id),
         %SessionRecording{} = recording <-
           SessionRecording
           |> where([r], r.id == ^uuid and r.patient_id == ^patient.id)
           |> with_audio_stored()
           |> Repo.one() do
      {:ok, recording}
    else
      _ -> {:error, :not_found}
    end
  end

  defp with_audio_stored(query) do
    select_merge(query, [r], %{
      audio_stored?:
        fragment(
          "EXISTS (SELECT 1 FROM session_recording_chunks c WHERE c.session_recording_id = ?)",
          r.id
        )
    })
  end

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_id), do: {:error, :not_found}

  defp chunks_stored?(recording_id) do
    SessionRecordingChunk
    |> where([c], c.session_recording_id == ^recording_id)
    |> Repo.exists?()
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

      # Re-read the row under a lock: two submits that both loaded the
      # recording while it needed speakers must not both create a transcript.
      Repo.transaction(fn ->
        with {:ok, recording} <- lock_in_status(recording.id, "needs_speakers"),
             {:ok, transcript} <- create_transcript(professional, patient, recording, spans),
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

  # Re-reads the row FOR UPDATE and requires `status`, so two requests that
  # loaded the same recording cannot both move it on.
  defp lock_in_status(id, status) do
    SessionRecording
    |> where([r], r.id == ^id and r.status == ^status)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_status}
      recording -> {:ok, recording}
    end
  end

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
    Repo.transaction(fn ->
      with {:ok, recording} <- lock_in_status(recording.id, "failed"),
           true <- chunks_stored?(recording.id) || {:error, :not_retryable},
           {:ok, updated} <-
             recording
             |> SessionRecording.transition_changeset(%{status: "transcribing", error_code: nil})
             |> Repo.update(),
           {:ok, _job} <-
             Oban.insert(SessionTranscriptionWorker.new(%{"session_recording_id" => updated.id})) do
        %{updated | audio_stored?: true}
      else
        {:error, :invalid_status} -> Repo.rollback(:not_retryable)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> broadcast_on_ok()
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
                 audio_duration_seconds: duration,
                 error_code: nil
               })
               |> Repo.update(),
             :ok <- delete_chunks(recording.id),
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
               audio_duration_seconds: duration,
               error_code: nil
             })
             |> Repo.update(),
           :ok <- delete_chunks(recording.id),
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
    Repo.transaction(fn ->
      case mark_failed(professional.id, recording, code) do
        {:ok, updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> log_failure_on_ok(code)
    |> broadcast_on_ok()
  end

  # Must run inside a transaction. Deletes the audio chunks: a failed
  # recording keeps no audio.
  defp mark_failed(professional_id, recording, code) do
    with {:ok, updated} <-
           recording
           |> SessionRecording.transition_changeset(%{status: "failed", error_code: code})
           |> Repo.update(),
         :ok <- delete_chunks(recording.id),
         {:ok, _audit} <-
           Repo.insert(audit(professional_id, "session_recording_failed", recording.id)) do
      {:ok, %{updated | audio_stored?: false}}
    end
  end

  defp delete_chunks(recording_id) do
    SessionRecordingChunk
    |> where([c], c.session_recording_id == ^recording_id)
    |> Repo.delete_all()

    :ok
  end

  defp log_failure_on_ok({:ok, _recording} = result, code) do
    Logger.warning("session recording failed: #{code}")
    result
  end

  defp log_failure_on_ok(error, _code), do: error

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

  # MediaRecorder timeslice chunks concatenate, in order, into one valid file.
  defp decrypt_audio(%SessionRecording{id: id}, keyring) do
    SessionRecordingChunk
    |> where([c], c.session_recording_id == ^id)
    |> order_by([c], asc: c.seq)
    |> select([c], c.encrypted_data)
    |> Repo.all()
    |> case do
      [] ->
        {:error, :audio_unavailable}

      ciphertexts ->
        Enum.reduce_while(ciphertexts, {:ok, []}, fn ciphertext, {:ok, acc} ->
          case PatientVault.decrypt(ciphertext, keyring.clinical_record_dek) do
            {:ok, data} -> {:cont, {:ok, [acc | data]}}
            {:error, _reason} -> {:halt, {:error, :audio_unavailable}}
          end
        end)
        |> case do
          {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
          error -> error
        end
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
