defmodule Alethea.AI.Chains.WeeklySummaryChain do
  @behaviour Alethea.AI.WeeklySummaryChainBehavior

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias Alethea.AI.ChatModels.HuggingFaceChat
  alias LangChain.Message

  @impl true
  def run(summaries, aggregated_trends) do
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
    Eres Alethea, un asistente clínico experto en análisis de tendencias terapéuticas.
    Genera un reporte semanal consolidado para el terapeuta en 8 líneas o menos:
    1. PANORAMA EMOCIONAL: Resume el estado de ánimo predominante de los últimos 7 días.
    2. PATRONES RECURRENTES: Identifica temas, conflictos o preocupaciones que se repitieron.
    3. HITOS DE LA SEMANA: Menciona cualquier evento o cambio de actitud significativo.
    4. NIVEL DE RIESGO: Elige exactamente uno: Estable / Alerta / Intervención Requerida.
    Responde en español, con rigor profesional y sin preámbulos.
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
