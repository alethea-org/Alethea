defmodule Alethea.AI.PhiWorker do
  @moduledoc """
  Worker de alto nivel que orquesta la ejecución de la chain de conversación guiada.

  Este módulo centraliza la sanitización y la invocación de LangChain sin lógica de negocio externa.
  """
  @behaviour Alethea.AI.PhiWorkerBehaviour

  alias Alethea.AI.Sanitizer
  alias Alethea.AI.Chains.GuidedConversationChain

  @impl true
  @spec process(%{message_id: binary(), raw_content: String.t(), patient_context: String.t()}) ::
          {:ok, map()} | {:error, term()}
  def process(%{
        message_id: message_id,
        raw_content: raw_content,
        patient_context: patient_context
      }) do
    sanitized_content = Sanitizer.sanitize(raw_content)

    # GuidedConversationChain.run devuelve un mapa de resultado directamente.
    # Lo envolvemos en {:ok, ...} para consistencia en el pipeline.
    case GuidedConversationChain.run(%{
           sanitized_content: sanitized_content,
           patient_context: patient_context,
           message_id: message_id
         }) do
      result when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end
end
