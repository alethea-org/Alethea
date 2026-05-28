defmodule Alethea.AI.Chains.GuidedConversationChain do
  @moduledoc """
  Chain inicial de LangChain para conversación guiada con un LLM externo.

  El contenido ya debe haber sido sanitizado por `Alethea.AI.Sanitizer`.
  """

  alias Alethea.AI.ChatModels.HuggingFaceChat
  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message

  @spec run(%{sanitized_content: String.t(), patient_context: String.t(), message_id: binary()}) ::
          map()
  def run(%{sanitized_content: content, patient_context: ctx, message_id: msg_id}) do
    llm_config = Application.get_env(:alethea, __MODULE__, [])
    provider = Keyword.get(llm_config, :provider, :local)
    provider_config = Keyword.get(llm_config, provider, [])

    endpoint_url =
      Keyword.get(llm_config, :endpoint_url) ||
        Keyword.get(llm_config, :endpoint) ||
        Keyword.get(provider_config, :endpoint_url) ||
        Keyword.get(provider_config, :endpoint) ||
        "https://api-inference.huggingface.co/models/"

    api_key = Keyword.get(llm_config, :api_key) || Keyword.get(provider_config, :api_key)

    llm_opts = %{
      model: Keyword.get(llm_config, :model, "phi-4-mini"),
      api_key: api_key,
      endpoint_url: endpoint_url,
      endpoint: endpoint_url,
      temperature: Keyword.get(llm_config, :temperature, 0.0),
      max_tokens: Keyword.get(llm_config, :max_tokens, 512),
      stream: Keyword.get(llm_config, :stream, false)
    }

    llm =
      case provider do
        :cloud -> ChatOpenAI.new!(llm_opts)
        _ -> HuggingFaceChat.new!(llm_opts)
      end

    system_msg = system_prompt(ctx, llm_config[:system_prompt])

    {:ok, chain} =
      %{
        llm: llm,
        verbose: false
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(system_msg))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    %{
      response: chain.last_message.content,
      source_message_id: msg_id,
      model_version: llm_config[:model] || "phi-4-mini",
      behavior_type: :elicited
    }
  end

  defp system_prompt(context, nil) do
    default_system_prompt() <> "\n\nContexto del paciente: #{context}"
  end

  defp system_prompt(context, custom_prompt) when is_binary(custom_prompt) do
    "#{custom_prompt}\n\nContexto del paciente: #{context}"
  end

  defp default_system_prompt do
    """
    Eres un asistente clínico de apoyo. Tu rol es escuchar y formular preguntas exploratorias.
    NO valides ni refutes los pensamientos del paciente sin instrucción explícita del terapeuta.
    Evita emitir diagnósticos o consejos médicos directos.
    """
  end
end
