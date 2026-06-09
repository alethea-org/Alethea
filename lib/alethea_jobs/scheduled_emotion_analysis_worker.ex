defmodule AletheaJobs.ScheduledEmotionAnalysisWorker do
  @moduledoc """
  Daily backfill worker for inbound messages without emotion analysis.
  """
  use Oban.Worker,
    queue: :ai_analysis,
    max_attempts: 1,
    unique: [
      fields: [:worker],
      period: 2 * 60 * 60,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Alethea.AI.Sanitizer
  alias Alethea.Clinical
  alias Alethea.Clinical.{EmotionAnalysis, Message}
  alias Alethea.Repo

  require Logger

  @default_max_messages 1_000
  @default_batch_size 100
  @timeout_ms :timer.hours(2)

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: @timeout_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    started_at = System.monotonic_time()
    max_messages = positive_integer_setting(args, :max_messages, @default_max_messages)
    batch_size = positive_integer_setting(args, :batch_size, @default_batch_size)

    result = process_messages(max_messages, batch_size)
    duration_ms = duration_ms(started_at)

    case result do
      {:ok, processed_count} ->
        Logger.info(
          "ScheduledEmotionAnalysisWorker completed batch_size=#{processed_count} duration_ms=#{duration_ms}",
          batch_size: processed_count,
          duration_ms: duration_ms
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "ScheduledEmotionAnalysisWorker failed duration_ms=#{duration_ms} reason=#{inspect(reason)}",
          duration_ms: duration_ms,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp roberta_worker do
    Application.get_env(:alethea, :roberta_worker, Alethea.AI.RoBERTaWorker)
  end

  defp process_messages(max_messages, batch_size) do
    messages = fetch_candidate_messages(max_messages)

    with {:ok, decrypted_by_id} <- decrypt_messages(messages) do
      messages
      |> Enum.map(fn message ->
        {message, decrypted_by_id |> Map.fetch!(message.id) |> Sanitizer.sanitize()}
      end)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, processed_count} ->
        case analyze_chunk(chunk) do
          {:ok, chunk_count} -> {:cont, {:ok, processed_count + chunk_count}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp fetch_candidate_messages(limit) do
    Repo.all(
      from m in Message,
        left_join: ea in assoc(m, :emotion_analysis),
        where: m.direction == "inbound" and is_nil(ea.id),
        order_by: [asc: m.timestamp, asc: m.id],
        limit: ^limit,
        preload: [:patient]
    )
  end

  defp decrypt_messages(messages) do
    messages
    |> Enum.group_by(& &1.patient_id)
    |> Enum.reduce_while({:ok, %{}}, fn {_patient_id, patient_messages}, {:ok, acc} ->
      with %Alethea.Accounts.Patient{} = patient <- hd(patient_messages).patient,
           {:ok, dek} <- Clinical.patient_dek(patient),
           {:ok, decrypted} <- decrypt_patient_messages(patient_messages, dek) do
        {:cont, {:ok, Map.merge(acc, decrypted)}}
      else
        nil -> {:halt, {:error, :missing_patient}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decrypt_patient_messages(messages, dek) do
    Enum.reduce_while(messages, {:ok, %{}}, fn message, {:ok, acc} ->
      case Clinical.decrypt_message_content(message, dek) do
        {:ok, text} ->
          {:cont, {:ok, Map.put(acc, message.id, text)}}

        {:error, reason} ->
          {:halt, {:error, {:decrypt_failed, message.id, reason}}}
      end
    end)
  end

  defp analyze_chunk(chunk) do
    texts = Enum.map(chunk, fn {_message, text} -> text end)

    case roberta_worker().analyze_batch_per_message(texts) do
      results when is_list(results) ->
        persist_chunk_results(chunk, results)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_roberta_response, other}}
    end
  end

  defp persist_chunk_results(chunk, results) when length(chunk) == length(results) do
    if Enum.all?(results, &is_list/1) do
      chunk
      |> Enum.zip(results)
      |> Enum.reduce_while({:ok, 0}, fn {{message, _text}, emotion_scores},
                                        {:ok, processed_count} ->
        case persist_message_analysis(message, emotion_scores) do
          {:inserted, _analysis} -> {:cont, {:ok, processed_count + 1}}
          :skipped -> {:cont, {:ok, processed_count}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :invalid_roberta_result_shape}
    end
  end

  defp persist_chunk_results(chunk, results) do
    {:error, {:roberta_result_count_mismatch, expected: length(chunk), got: length(results)}}
  end

  defp persist_message_analysis(%Message{} = message, emotion_scores) do
    case Repo.get_by(EmotionAnalysis, message_id: message.id) do
      %EmotionAnalysis{} ->
        :skipped

      nil ->
        attrs =
          EmotionAnalysis.attrs_from_scores(emotion_scores, %{
            message_id: message.id,
            processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        case %EmotionAnalysis{} |> EmotionAnalysis.changeset(attrs) |> Repo.insert() do
          {:ok, analysis} ->
            Clinical.save_trends_from_analysis(analysis, message.patient_id)
            {:inserted, analysis}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp positive_integer_setting(args, key, default) do
    args
    |> Map.get(to_string(key), Map.get(args, key))
    |> case do
      nil ->
        __MODULE__
        |> Application.get_env([])
        |> Keyword.get(key, default)

      value ->
        value
    end
    |> to_positive_integer(default)
  end

  defp to_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _invalid -> default
    end
  end

  defp to_positive_integer(_value, default), do: default

  defp duration_ms(started_at) do
    started_at
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :millisecond)
  end
end
