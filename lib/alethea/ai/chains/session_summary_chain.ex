defmodule Alethea.AI.Chains.SessionSummaryChain do
  @behaviour Alethea.AI.SessionSummaryChainBehavior

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message

  @impl true
  def run(message_texts, emotion_scores) do
    llm_config = Application.get_env(:alethea, Alethea.AI.Chains.GuidedConversationChain, [])
    llm = ChatOpenAI.new!(Keyword.merge([model: "phi-4-mini", stream: false], llm_config))

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
