defmodule AletheaJobs.EmotionAnalysisWorker do
  @moduledoc """
  Worker asíncrono para análisis de emociones.

  Este worker se encola después de guardar un mensaje y procesa
  el análisis de emociones sin bloquear el flujo principal.
  """
  use Oban.Worker, queue: :ai_analysis, max_attempts: 1

  alias Alethea.Repo
  alias Alethea.Clinical
  alias Alethea.Clinical.{Message, EmotionAnalysis}

  require Logger

  defp emotion_analyzer,
    do: Application.get_env(:alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzer)

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
         {:ok, emotion_scores} <- emotion_analyzer().analyze_batch([decrypted_content]),
         emotion_data when is_map(emotion_data) <- emotion_data(emotion_scores) do
      save_analysis(message, emotion_data)
    else
      {:error, reason} ->
        Logger.error("EmotionAnalysisWorker: error en procesamiento: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.error("EmotionAnalysisWorker: análisis de emociones no disponible")
        {:error, :invalid_emotion_scores}

      [] ->
        Logger.warning("EmotionAnalysisWorker: lista vacía de emociones")
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
      {:error, _} = error -> error
    end
  end

  defp decrypt_message(%Message{} = message, dek) do
    Clinical.decrypt_message_content(message, dek)
  end

  @doc false
  def emotion_data(scores) do
    case EmotionAnalysis.canonical_scores(scores) do
      {:ok, data} -> data
      {:error, :invalid_emotion_scores} -> nil
    end
  end

  defp save_analysis(%Message{} = message, emotion_data) do
    analysis = %EmotionAnalysis{
      message_id: message.id,
      model_version: "emotion-analyzer-v1",
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    attrs = Map.merge(emotion_data, %{message_id: message.id})

    case EmotionAnalysis.changeset(analysis, attrs) |> Repo.insert() do
      {:ok, saved_analysis} ->
        # Actualizar tendencias clínicas
        Clinical.save_trends_from_analysis(saved_analysis, message.patient_id)
        notify_dashboard(message.patient_id)

        Logger.info("EmotionAnalysisWorker: análisis guardado para mensaje #{message.id}")

        {:ok, saved_analysis}

      {:error, changeset} ->
        Logger.error("EmotionAnalysisWorker: error guardando análisis: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  defp notify_dashboard(patient_id) do
    case Repo.get(Alethea.Accounts.Patient, patient_id) do
      %Alethea.Accounts.Patient{professional_id: professional_id} ->
        Phoenix.PubSub.broadcast(
          Alethea.PubSub,
          "patients:#{professional_id}",
          {:emotion_trends_updated, patient_id}
        )

      nil ->
        :ok
    end
  end
end
