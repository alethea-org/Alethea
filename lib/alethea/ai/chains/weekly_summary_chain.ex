defmodule Alethea.AI.Chains.WeeklySummaryChain do
  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message

  def run(summaries, aggregated_trends) do
    llm_config = Application.get_env(:alethea, Alethea.AI.Chains.GuidedConversationChain, [])
    llm = ChatOpenAI.new!(Keyword.merge([model: "phi-4-mini", stream: false], llm_config))

    content = build_prompt(summaries, aggregated_trends)

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
    Eres un asistente clínico. Genera un reporte semanal en 8 líneas o menos:
    1. Estado emocional general de la semana
    2. Temas recurrentes entre sesiones
    3. Eventos o cambios significativos
    4. Nivel de riesgo observado (Estable / Alerta / Intervención Requerida)
    Responde en español. Sin introducción ni cierre.
    """
  end

  defp build_prompt(summaries, trends) do
    summaries_section =
      summaries
      |> Enum.map(fn s -> s.summary_text end)
      |> Enum.join("\n---\n")

    trends_section =
      trends
      |> Enum.map(fn %{label: label, score: score} ->
        "#{label}: #{Float.round(score * 1.0, 2)}"
      end)
      |> Enum.join(", ")

    "Resúmenes de sesiones de la semana:\n#{summaries_section}\n\nTendencias emocionales: #{trends_section}"
  end
end
