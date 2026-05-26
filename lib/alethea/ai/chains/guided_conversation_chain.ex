defmodule Alethea.AI.Chains.GuidedConversationChain do
  @moduledoc """
  Chain inicial de LangChain para conversación guiada con un LLM externo.

  El contenido ya debe haber sido sanitizado por `Alethea.AI.Sanitizer`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias Alethea.AI.ChatModels.HuggingFaceChat
  alias LangChain.Message

  @spec run(%{sanitized_content: String.t(), patient_context: String.t(), message_id: binary()}) ::
          map()
  def run(%{sanitized_content: content, patient_context: ctx, message_id: msg_id}) do
    llm_config = Application.get_env(:alethea, __MODULE__, [])

    llm =
      case llm_config[:adapter] do
        :hugging_face ->
          HuggingFaceChat.new!(%{
            model: llm_config[:model] || "phi-4-mini",
            endpoint: llm_config[:endpoint_url] || "https://api-inference.huggingface.co/models",
            api_key: llm_config[:api_key],
            stream: false
          })

        _ ->
          ChatOpenAI.new!(%{
            model: llm_config[:model] || "phi-4-mini",
            endpoint: llm_config[:endpoint_url],
            api_key: llm_config[:api_key],
            stream: false
          })
      end

    system_msg = system_prompt(ctx, llm_config[:system_prompt])

    {:ok, _updated_chain, response} =
      %{
        llm: llm,
        verbose: false
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(system_msg))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    %{
      ai_response: response.content,
      source_message_id: msg_id,
      model_version: llm_config[:model] || "phi-4-mini",
      behavior_type: "elicited"
    }
  end

  defp system_prompt(patient_history, base_prompt) do
    """
    #{base_prompt}

    A continuación se presenta el historial reciente de la conversación con el paciente
    (los mensajes más recientes están al final):
    ---
    #{patient_history}
    ---
    """
  end
end
