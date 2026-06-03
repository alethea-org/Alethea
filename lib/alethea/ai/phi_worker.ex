defmodule Alethea.AI.PhiWorker do
  @moduledoc """
  Worker de alto nivel que orquesta la ejecución de la chain de conversación guiada.

  Este módulo centraliza la sanitización, obtención de emociones y la invocación de LangChain.
  """
  @behaviour Alethea.AI.PhiWorkerBehaviour

  alias Alethea.AI.Sanitizer
  alias Alethea.AI.Chains.GuidedConversationChain
  alias Alethea.Clinical
  alias Alethea.Clinical.EmotionAnalysis

  @impl true
  @spec process(%{message_id: binary(), raw_content: String.t(), patient_context: String.t()}) ::
          {:ok, map()} | {:error, term()}
  def process(%{
        message_id: message_id,
        raw_content: raw_content,
        patient_context: patient_context
      }) do
    sanitized_content = Sanitizer.sanitize(raw_content)

    # Obtener análisis de emociones para enriquecer el contexto
    emotion_context =
      case Clinical.get_message_emotions(message_id) do
        {:ok, emotion_analysis} ->
          format_emotion_context(emotion_analysis)

        {:error, :not_found} ->
          ""
      end

    enriched_context =
      if emotion_context != "" do
        "#{patient_context}\n\n## Análisis Emocional del Mensaje\n#{emotion_context}"
      else
        patient_context
      end

    GuidedConversationChain.run(%{
      sanitized_content: sanitized_content,
      patient_context: enriched_context,
      message_id: message_id
    })
  end

  defp format_emotion_context(%EmotionAnalysis{} = analysis) do
    """
    Emociones detectadas:
    - Alegría: #{format_score(analysis.joy_score)}
    - Tristeza: #{format_score(analysis.sadness_score)}
    - Ira: #{format_score(analysis.anger_score)}
    - Miedo: #{format_score(analysis.fear_score)}
    - Neutral: #{format_score(analysis.neutral_score)}
    Emoción dominante: #{analysis.dominant_label || "indeterminado"}
    Confianza: #{format_score(analysis.confidence)}
    """
  end

  defp format_score(nil), do: "N/A"
  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 3)
end
