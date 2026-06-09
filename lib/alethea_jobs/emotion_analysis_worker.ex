defmodule AletheaJobs.EmotionAnalysisWorker do
  @moduledoc """
  Asynchronous worker for RoBERTa emotion analysis on a single message.
  """
  use Oban.Worker, queue: :ai_analysis, max_attempts: 1

  alias Alethea.Repo
  alias Alethea.Clinical
  alias Alethea.Clinical.{EmotionAnalysis, Message}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    case Clinical.get_message(message_id) do
      {:ok, message} ->
        process_message(message)

      {:error, :not_found} ->
        Logger.warning("EmotionAnalysisWorker: mensaje no encontrado #{message_id}")
        :ok

      {:error, reason} ->
        Logger.error("EmotionAnalysisWorker: error obteniendo mensaje: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp roberta_worker do
    Application.get_env(:alethea, :roberta_worker, Alethea.AI.RoBERTaWorker)
  end

  defp process_message(%Message{} = message) do
    with {:ok, dek} <- get_dek_for_message(message),
         {:ok, decrypted_content} <- Clinical.decrypt_message_content(message, dek),
         emotion_scores when is_list(emotion_scores) <-
           roberta_worker().analyze_batch([decrypted_content]) do
      save_analysis(message, emotion_scores)
    else
      {:error, reason} ->
        Logger.error("EmotionAnalysisWorker: error en procesamiento: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.error("EmotionAnalysisWorker: RoBERTa devolvio nil")
        {:error, :roberta_returned_nil}

      [] ->
        Logger.warning("EmotionAnalysisWorker: lista vacia de emociones")
        :ok
    end
  end

  defp get_dek_for_message(%Message{} = message) do
    message = Repo.preload(message, :patient)

    with %Alethea.Accounts.Patient{} = patient <- message.patient,
         {:ok, dek} <- Clinical.patient_dek(patient) do
      {:ok, dek}
    else
      nil -> {:error, :missing_patient}
      {:error, _reason} = error -> error
    end
  end

  defp save_analysis(%Message{} = message, emotion_scores) do
    attrs =
      EmotionAnalysis.attrs_from_scores(emotion_scores, %{
        message_id: message.id,
        processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    case %EmotionAnalysis{} |> EmotionAnalysis.changeset(attrs) |> Repo.insert() do
      {:ok, saved_analysis} ->
        Clinical.save_trends_from_analysis(saved_analysis, message.patient_id)

        Logger.info("EmotionAnalysisWorker: analisis guardado para mensaje #{message.id}")

        {:ok, saved_analysis}

      {:error, changeset} ->
        Logger.error("EmotionAnalysisWorker: error guardando analisis: #{inspect(changeset)}")
        {:error, changeset}
    end
  end
end
