defmodule Alethea.AI.Chains.WeeklySummaryChain do
  @moduledoc false
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.{LLMConfig, StructuredOutput}
  alias Alethea.AI.Chains.SafeRun
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @status_levels ["Estable", "Alerta", "Intervención Requerida"]

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

  @typedoc """
  Reporte semanal estructurado: exactamente las claves que hoy se persisten
  (`tokens_used` lo agrega `do_run/3`, no el parser).
  """
  @type report :: %{
          summary_text: String.t(),
          status_level: String.t(),
          anxiety_score: float() | nil,
          social_score: float() | nil,
          emotional_range: map() | nil,
          crisis_events: non_neg_integer() | nil,
          session_count: non_neg_integer() | nil
        }

  @doc """
  Parser puro de la respuesta del modelo (#360): decode con limpieza de fences
  → detección de eco del esquema → `unwrap_schema_echo/1` (opt-in) →
  validación estricta de `summary_text` (binario no vacío) y `status_level`
  (exactamente el enum clínico). Las métricas mantienen el parsing leniente de
  antes y `session_count` conserva el conteo local como fallback.

  Un eco del esquema que no desenvuelve datos clínicos válidos se rechaza con
  `{:error, :schema_echo}`; todo lo demás que falla la validación es
  `{:error, :unparseable}`. Nunca se deduce el estado clínico escaneando el
  texto crudo: solo una respuesta clínica válida produce un reporte.
  """
  @spec parse(String.t(), non_neg_integer()) ::
          {:ok, report()} | {:error, :schema_echo | :unparseable}
  def parse(raw, session_count) when is_binary(raw) do
    with {:ok, decoded} <- StructuredOutput.parse_json_response(raw) do
      unwrapped = StructuredOutput.unwrap_schema_echo(decoded)

      case build_report(unwrapped, session_count) do
        {:ok, report} ->
          {:ok, report}

        {:error, :unparseable} ->
          if schema_echo?(decoded), do: {:error, :schema_echo}, else: {:error, :unparseable}
      end
    else
      _error -> {:error, :unparseable}
    end
  end

  defp do_run(llm, content, session_count) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :weekly_summary}, %{})

    result =
      %{llm: llm, verbose: false}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(suggested_system_prompt()))
      |> LLMChain.add_message(Message.new_user!(content))
      |> SafeRun.run()

    duration = System.monotonic_time(:millisecond) - start_time

    {telemetry_meta, parsed} =
      case result do
        {:ok, chain} ->
          raw = chain.last_message.content

          case parse(raw, session_count) do
            {:ok, report} ->
              meta = %{
                chain: :weekly_summary,
                duration_ms: duration,
                response_length: byte_size(raw)
              }

              {meta, {:ok, Map.put(report, :tokens_used, estimate_tokens(content))}}

            {:error, reason} ->
              meta = %{
                chain: :weekly_summary,
                duration_ms: duration,
                response_length: byte_size(raw),
                error: inspect(reason)
              }

              {meta, {:error, reason}}
          end

        {:error, reason} ->
          meta = %{chain: :weekly_summary, duration_ms: duration, error: inspect(reason)}
          {meta, {:error, reason}}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, telemetry_meta)
    parsed
  end

  defp build_report(decoded, session_count) when is_map(decoded) do
    with summary_text when is_binary(summary_text) <- Map.get(decoded, "summary_text"),
         true <- String.trim(summary_text) != "",
         status_level when status_level in @status_levels <- Map.get(decoded, "status_level") do
      {:ok,
       %{
         summary_text: summary_text,
         status_level: status_level,
         anxiety_score: parse_float(Map.get(decoded, "anxiety_score")),
         social_score: parse_float(Map.get(decoded, "social_score")),
         emotional_range: parse_emotional_range(Map.get(decoded, "emotional_range")),
         crisis_events: parse_non_neg_integer(Map.get(decoded, "crisis_events")),
         session_count: parse_non_neg_integer(Map.get(decoded, "session_count")) || session_count
       }}
    else
      _other -> {:error, :unparseable}
    end
  end

  defp build_report(_other, _session_count), do: {:error, :unparseable}

  # Un eco del esquema se reconoce por un "properties" de nivel superior o por
  # la forma completa del esquema embebido en el prompt ("type" => "object" +
  # "required" como lista). Solo clasifica el motivo del error; nunca descarta
  # una carga cuyos valores sí validan como datos clínicos.
  defp schema_echo?(decoded) when is_map(decoded) do
    is_map(Map.get(decoded, "properties")) or
      (Map.get(decoded, "type") == "object" and is_list(Map.get(decoded, "required")))
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
