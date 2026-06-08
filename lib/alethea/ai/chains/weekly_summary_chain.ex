defmodule Alethea.AI.Chains.WeeklySummaryChain do
  @moduledoc false
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.{LLMConfig, StructuredOutput}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{summaries: summaries, trends: trends}) when is_list(summaries) and is_list(trends) do
    session_count = length(summaries)
    content = build_prompt(summaries, trends, session_count)

    case LLMConfig.get_and_build(:weekly_summary) do
      {:ok, _config, llm} -> do_run(llm, content, session_count)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run(summaries, trends), do: run(%{summaries: summaries, trends: trends})

  @impl true
  def run!(params) do
    {:ok, result} = run(params)
    result
  end

  @impl true
  def suggested_system_prompt do
    base = """
    Eres Alethea, un asistente clínico experto en análisis de tendencias terapéuticas.
    Genera un reporte semanal consolidado para el terapeuta. Incluye:
    - summary_text: narrativa clínica en 8 líneas o menos (panorama emocional, patrones recurrentes, hitos, nivel de riesgo)
    - status_level: exactamente uno de "Estable", "Alerta", "Intervención Requerida"
    - anxiety_score: 0.0-1.0 estimado de niveles de ansiedad de la semana
    - social_score: 0.0-1.0 estimado de funcionamiento social/vinculación
    - emotional_range: objeto con scores promedio de joy, sadness, anger, fear, neutral (0.0-1.0 cada uno)
    - crisis_events: número de episodios de crisis identificados
    - session_count: número de sesiones incluidas en este reporte
    Responde en español con rigor profesional.
    """

    StructuredOutput.with_schema(base, StructuredOutput.weekly_summary_schema())
  end

  @impl true
  def suggested_max_tokens, do: 768

  @impl true
  def supported_providers, do: [:local, :cloud]

  defp do_run(llm, content, session_count) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :weekly_summary}, %{})

    result =
      %{llm: llm, verbose: false}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(suggested_system_prompt()))
      |> LLMChain.add_message(Message.new_user!(content))
      |> LLMChain.run()

    duration = System.monotonic_time(:millisecond) - start_time

    {telemetry_meta, parsed} =
      case result do
        {:ok, chain} ->
          raw = chain.last_message.content
          structured = parse_structured_response(raw, session_count)

          meta = %{
            chain: :weekly_summary,
            duration_ms: duration,
            response_length: byte_size(raw)
          }

          {meta, {:ok, Map.put(structured, :tokens_used, estimate_tokens(content))}}

        {:error, reason} ->
          meta = %{chain: :weekly_summary, duration_ms: duration, error: inspect(reason)}
          {meta, {:error, reason}}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, telemetry_meta)
    parsed
  end

  defp parse_structured_response(raw, session_count) do
    case StructuredOutput.parse_json_response(raw) do
      {:ok, map} ->
        %{
          summary_text: Map.get(map, "summary_text") || raw,
          status_level: Map.get(map, "status_level") || infer_status_level(raw),
          anxiety_score: parse_float(Map.get(map, "anxiety_score")),
          social_score: parse_float(Map.get(map, "social_score")),
          emotional_range: parse_emotional_range(Map.get(map, "emotional_range")),
          crisis_events: parse_non_neg_integer(Map.get(map, "crisis_events")),
          session_count: parse_non_neg_integer(Map.get(map, "session_count")) || session_count
        }

      {:error, _} ->
        %{
          summary_text: raw,
          status_level: infer_status_level(raw),
          anxiety_score: nil,
          social_score: nil,
          emotional_range: nil,
          crisis_events: nil,
          session_count: session_count
        }
    end
  end

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0
  defp parse_float(_), do: nil

  defp parse_non_neg_integer(v) when is_integer(v) and v >= 0, do: v
  defp parse_non_neg_integer(_), do: nil

  defp parse_emotional_range(map) when is_map(map) do
    keys = ~w(joy sadness anger fear neutral)

    parsed =
      Map.new(keys, fn k ->
        {k, parse_float(Map.get(map, k))}
      end)

    if Enum.all?(parsed, fn {_, v} -> is_nil(v) end), do: nil, else: parsed
  end

  defp parse_emotional_range(_), do: nil

  defp infer_status_level(text) do
    cond do
      String.contains?(text, "Intervención") -> "Intervención Requerida"
      String.contains?(text, "Alerta") -> "Alerta"
      true -> "Estable"
    end
  end

  defp build_prompt(summaries, trends, session_count) do
    summaries_text = Enum.map_join(summaries, "\n---\n", &extract_summary_text/1)

    trends_text =
      Enum.map_join(trends, ", ", fn %{label: l, score: s} ->
        "#{l}: #{Float.round(s * 1.0, 2)}"
      end)

    """
    Sesiones incluidas: #{session_count}

    Resúmenes de sesiones de la semana:
    #{summaries_text}

    Tendencias emocionales agregadas: #{trends_text}
    """
  end

  defp extract_summary_text(%{summary_text: t}) when is_binary(t), do: t
  defp extract_summary_text(%{summary: t}) when is_binary(t), do: t
  defp extract_summary_text(t) when is_binary(t), do: t
  defp extract_summary_text(_), do: ""

  defp estimate_tokens(text), do: div(String.length(text), 4)
end
