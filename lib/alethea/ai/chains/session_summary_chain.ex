defmodule Alethea.AI.Chains.SessionSummaryChain do
  @behaviour Alethea.AI.SessionSummaryChainBehavior

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias Alethea.AI.ChatModels.HuggingFaceChat
  alias LangChain.Message

  @impl true
  def run(message_texts, emotion_scores) do
    llm_config = Application.get_env(:alethea, Alethea.AI.Chains.GuidedConversationChain, [])
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
      temperature: 0.0,
      max_tokens: 512,
      stream: false
    }

    llm =
      case provider do
        :cloud -> ChatOpenAI.new!(llm_opts)
        _ -> HuggingFaceChat.new!(llm_opts)
      end

    content = build_prompt(message_texts, emotion_scores)

    {:ok, chain} =
      %{llm: llm, verbose: false}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(system_prompt()))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    {:ok, chain.last_message.content}
  end

  defp system_prompt do
    """
    Eres un asistente clínico. Genera un snapshot de sesión en exactamente 4 líneas numeradas:
    1. Estado emocional predominante de la sesión
    2. Temas principales tratados
    3. Cambios observados respecto a sesiones anteriores
    4. Nivel de atención requerido (exactamente uno de: Estable / Alerta / Intervención Requerida)
    Responde en español. Sin introducción ni cierre.
    """
  end

  defp build_prompt(texts, scores) do
    messages_section = Enum.join(texts, "\n---\n")
    emotions_section = format_emotions(scores)
    "Mensajes de la sesión:\n#{messages_section}\n\nPerfil emocional: #{emotions_section}"
  end

  defp format_emotions(scores) do
    scores
    |> Enum.map(fn %{label: label, score: score} -> "#{label}: #{Float.round(score * 1.0, 2)}" end)
    |> Enum.join(", ")
  end
end
