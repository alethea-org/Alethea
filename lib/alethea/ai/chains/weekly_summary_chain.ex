defmodule Alethea.AI.Chains.WeeklySummaryChain do
  @moduledoc false
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.LLMConfig
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{summaries: summaries, trends: trends}) when is_list(summaries) and is_list(trends) do
    content = build_prompt(summaries, trends)

    case LLMConfig.get_and_build(:weekly_summary) do
      {:ok, _config, llm} -> do_run(llm, content)
      {:error, reason} -> {:error, reason}
    end
  end

  def run(summaries, trends), do: run(%{summaries: summaries, trends: trends})

  @impl true
  def run!(params) do
    {:ok, result} = run(params)
    result
  end

  @impl true
  def suggested_system_prompt,
    do: """
    Eres Alethea, un asistente clínico experto en análisis de tendencias terapéuticas.
    Genera un reporte semanal consolidado para el terapeuta en 8 líneas o menos:
    1. PANORAMA EMOCIONAL: Resume el estado de ánimo predominante de los últimos 7 días.
    2. PATRONES RECURRENTES: Identifica temas, conflictos o preocupaciones que se repitieron.
    3. HITOS DE LA SEMANA: Menciona cualquier evento o cambio de actitud significativo.
    4. NIVEL DE RIESGO: Elige exactamente uno: Estable / Alerta / Intervención Requerida.
    Responde en español, con rigor profesional y sin preámbulos.
    """

  @impl true
  def suggested_max_tokens, do: 512

  @impl true
  def supported_providers, do: [:local, :cloud]

  defp do_run(llm, content) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :weekly_summary}, %{})

    result =
      %{llm: llm, verbose: false}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(suggested_system_prompt()))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    duration = System.monotonic_time(:millisecond) - start_time

    metadata =
      case result do
        {:ok, chain} ->
          %{
            chain: :weekly_summary,
            duration_ms: duration,
            response_length: byte_size(chain.last_message.content)
          }

        {:error, reason} ->
          %{chain: :weekly_summary, duration_ms: duration, error: inspect(reason)}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, metadata)

    case result do
      {:ok, chain} ->
        {:ok, %{summary: chain.last_message.content, tokens_used: estimate_tokens(content)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(summaries, trends) do
    summaries_text = Enum.map_join(summaries, "\n---\n", &extract_summary_text/1)

    trends_text =
      Enum.map_join(trends, ", ", fn %{label: l, score: s} -> "#{l}: #{Float.round(s, 2)}" end)

    "Resúmenes de sesiones de la semana:\n#{summaries_text}\n\nTendencias emocionales: #{trends_text}"
  end

  defp extract_summary_text(%{summary_text: t}), do: t
  defp extract_summary_text(%{summary: t}), do: t
  defp extract_summary_text(t) when is_binary(t), do: t

  defp estimate_tokens(text), do: div(String.length(text), 4)
end
