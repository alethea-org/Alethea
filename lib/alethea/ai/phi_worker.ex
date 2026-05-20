defmodule Alethea.AI.PhiWorker do
  @moduledoc """
  Worker de alto nivel que orquesta la ejecución de la chain de conversación guiada.

  Este módulo centraliza la sanitización y la invocación de LangChain sin lógica de negocio externa.
  """

  alias Alethea.AI.Sanitizer
  alias Alethea.AI.Chains.GuidedConversationChain

  @spec process(%{message_id: binary(), raw_content: String.t(), patient_context: String.t()}) :: map()
  def process(%{message_id: message_id, raw_content: raw_content, patient_context: patient_context}) do
    sanitized_content = Sanitizer.sanitize(raw_content)

    GuidedConversationChain.run(%{
      sanitized_content: sanitized_content,
      patient_context: patient_context,
      message_id: message_id
    })
  end
end
