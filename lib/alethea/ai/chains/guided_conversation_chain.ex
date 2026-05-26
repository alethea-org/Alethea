defmodule Alethea.AI.Chains.GuidedConversationChain do
  @moduledoc """
  Chain inicial de LangChain para conversación guiada con un LLM externo.

  El contenido ya debe haber sido sanitizado por `Alethea.AI.Sanitizer`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message

  @spec run(%{sanitized_content: String.t(), patient_context: String.t(), message_id: binary()}) :: map()
  def run(%{sanitized_content: content, patient_context: ctx, message_id: msg_id}) do
    llm_config = Application.get_env(:alethea, __MODULE__, [])
    provider = Keyword.get(llm_config, :provider, :cloud)
    provider_config = Keyword.get(llm_config, provider, [])

    llm_opts =
      provider_config
      |> Keyword.merge(model: llm_config[:model] || "phi-4-mini", stream: false)

    llm = ChatOpenAI.new!(llm_opts)

    {:ok, chain} =
      %{
        llm: llm,
        verbose: false
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(system_prompt(llm_config, ctx)))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    %{
      response: chain.last_message.content,
      source_message_id: msg_id,
      model_version: llm_config[:model] || "phi-4-mini",
      behavior_type: :elicited
    }
  end

  defp system_prompt(llm_config, context) do
    prompt = llm_config[:system_prompt] || default_system_prompt()

    "#{prompt}\n\nContexto del paciente: #{context}"
  end

  defp default_system_prompt do
    """
    Eres un asistente clínico de apoyo. Tu única función es escuchar y formular
    preguntas exploratorias con tono socrático.
    PROHIBIDO: emitir diagnósticos, validar o refutar pensamientos del paciente,
    dar consejos médicos directos o sugerir tratamientos.
    (Nota: El control de crisis y el envío del mensaje de soporte ante riesgo de daño propio/terceros se realiza en una capa perimetral/bypass previa.)
    """
  end
end
