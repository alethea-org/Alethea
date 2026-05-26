defmodule Alethea.AI.Chains.GuidedConversationChain do
  @moduledoc """
  Chain inicial de LangChain para conversación guiada con un LLM externo.

  El contenido ya debe haber sido sanitizado por `Alethea.AI.Sanitizer`.
  """

  alias Alethea.AI.ChatModels.HuggingFaceChat
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @spec run(%{sanitized_content: String.t(), patient_context: String.t(), message_id: binary()}) ::
          map()
  def run(%{sanitized_content: content, patient_context: ctx, message_id: msg_id}) do
    llm_config = Application.get_env(:alethea, __MODULE__, [])

    llm =
      HuggingFaceChat.new!(
        Keyword.merge(
          %{model: "phi-4-mini", stream: false, temperature: 0.0, max_tokens: 512},
          llm_config
        )
      )

    {:ok, chain} =
      %{
        llm: llm,
        verbose: false
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(system_prompt(ctx)))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    %{
      response: chain.last_message.content,
      source_message_id: msg_id,
      model_version: llm_config[:model] || "phi-4-mini",
      behavior_type: :elicited
    }
  end

  defp system_prompt(context) do
    """
    Eres un asistente clínico de apoyo. Tu rol es escuchar y formular preguntas exploratorias.
    NO valides ni refutes los pensamientos del paciente sin instrucción explícita del terapeuta.
    Contexto del paciente: #{context}
    """
  end
end
