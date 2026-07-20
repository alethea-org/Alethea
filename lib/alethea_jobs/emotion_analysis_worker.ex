defmodule AletheaJobs.EmotionAnalysisWorker do
  @moduledoc """
  Worker asíncrono para análisis de emociones con RoBERTa.

  Este worker se encola después de guardar un mensaje y procesa
  el análisis de sentimientos sin bloquear el flujo principal.
  """
  use Oban.Worker, queue: :ai_analysis, max_attempts: 1

  alias Alethea.Repo
  alias Alethea.AI.RoBERTaWorker
  alias Alethea.Clinical
  alias Alethea.Clinical.{Message, EmotionAnalysis}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    case Clinical.get_message(message_id) do
      {:ok, message} ->
        process_message(message)

      {:error, :not_found} ->
        Logger.warning("EmotionAnalysisWorker: mensaje no encontrado #{message_id}")
        :ok
    end
  end

  defp process_message(%Message{} = message) do
    with {:ok, dek} <- get_dek_for_message(message),
         {:ok, decrypted_content} <- decrypt_message(message, dek),
         emotion_scores when is_list(emotion_scores) <-
           RoBERTaWorker.analyze_batch([decrypted_content]),
         emotion_data <- extract_emotion_data(emotion_scores) do
      save_analysis(message, emotion_data)
    else
      {:error, reason} ->
        Logger.error("EmotionAnalysisWorker: error en procesamiento: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.error("EmotionAnalysisWorker: RoBERTa devolvió nil")
        {:error, :roberta_returned_nil}

      [] ->
        Logger.warning("EmotionAnalysisWorker: lista vacía de emociones")
        :ok
    end
  end

  @labels [:joy, :sadness, :anger, :fear, :neutral]

  defp get_dek_for_message(%Message{} = message) do
    message = Repo.preload(message, :patient)

    with %Alethea.Accounts.Patient{} = patient <- message.patient,
         {:ok, dek} <- Clinical.patient_dek(patient) do
      {:ok, dek}
    else
      nil -> {:error, :missing_patient}
      {:error, _} = error -> error
    end
  end

  defp decrypt_message(%Message{} = message, dek) do
    Clinical.decrypt_message_content(message, dek)
  end

  defp extract_emotion_data([single_result]) do
    %{
      joy_score: get_score(single_result, :joy),
      sadness_score: get_score(single_result, :sadness),
      anger_score: get_score(single_result, :anger),
      fear_score: get_score(single_result, :fear),
      neutral_score: get_score(single_result, :neutral),
      dominant_label: get_dominant_label(single_result),
      confidence: get_confidence(single_result)
    }
  end

  defp extract_emotion_data([_ | _] = results) do
    # Para batch de un solo elemento, promediamos (no debería pasar pero por seguridad)
    base_scores = %{
      joy: 0.0,
      sadness: 0.0,
      anger: 0.0,
      fear: 0.0,
      neutral: 0.0
    }

    totals =
      Enum.reduce(results, base_scores, fn result, acc ->
        Enum.map(@labels, fn label ->
          {label, Map.get(acc, label) + get_score(result, label)}
        end)
        |> Map.new()
      end)

    count = length(results)

    %{
      joy_score: totals.joy / count,
      sadness_score: totals.sadness / count,
      anger_score: totals.anger / count,
      fear_score: totals.fear / count,
      neutral_score: totals.neutral / count,
      dominant_label:
        get_dominant_label_from_scores(
          totals.joy,
          totals.sadness,
          totals.anger,
          totals.fear,
          totals.neutral
        ),
      confidence: nil
    }
  end

  defp get_score(result, label) when is_map(result) do
    key = :"#{label}_score"
    Map.get(result, key, 0.0) || 0.0
  end

  defp get_dominant_label(result) do
    scores = %{
      joy: get_score(result, :joy),
      sadness: get_score(result, :sadness),
      anger: get_score(result, :anger),
      fear: get_score(result, :fear),
      neutral: get_score(result, :neutral)
    }

    {label, _score} = Enum.max_by(scores, fn {_, v} -> v end, fn -> {:neutral, 0.0} end)
    to_string(label)
  end

  defp get_confidence(result) do
    scores = %{
      joy: get_score(result, :joy),
      sadness: get_score(result, :sadness),
      anger: get_score(result, :anger),
      fear: get_score(result, :fear),
      neutral: get_score(result, :neutral)
    }

    {_, max_score} = Enum.max_by(scores, fn {_, v} -> v end, fn -> {:neutral, 0.0} end)
    max_score
  end

  defp get_dominant_label_from_scores(joy, sadness, anger, fear, neutral) do
    scores = %{joy: joy, sadness: sadness, anger: anger, fear: fear, neutral: neutral}

    {label, _} =
      Enum.max_by(scores, fn {_, v} -> v end, fn -> {:neutral, 0.0} end)

    to_string(label)
  end

  defp save_analysis(%Message{} = message, emotion_data) do
    analysis = %EmotionAnalysis{
      message_id: message.id,
      model_version: "robertuito-emotion-analysis",
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    attrs = Map.merge(emotion_data, %{message_id: message.id})

    case EmotionAnalysis.changeset(analysis, attrs) |> Repo.insert() do
      {:ok, saved_analysis} ->
        # Actualizar tendencias clínicas
        Clinical.save_trends_from_analysis(saved_analysis, message.patient_id)

        Logger.info("EmotionAnalysisWorker: análisis guardado para mensaje #{message.id}")

        {:ok, saved_analysis}

      {:error, changeset} ->
        Logger.error("EmotionAnalysisWorker: error guardando análisis: #{inspect(changeset)}")
        {:error, changeset}
    end
  end
end
