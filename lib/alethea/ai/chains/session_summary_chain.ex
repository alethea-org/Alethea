defmodule Alethea.AI.Chains.SessionSummaryChain do
  @moduledoc false
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.LLMConfig
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{sanitized_content: texts, emotion_scores: scores})
      when is_list(texts) and is_list(scores) do
    content = build_prompt(texts, scores)

    case LLMConfig.get_and_build(:session_summary) do
      {:ok, _config, llm} -> do_run(llm, content)
      {:error, reason} -> {:error, reason}
    end
  end

  def run(texts, scores) when is_list(texts) and is_list(scores) do
    run(%{sanitized_content: texts, emotion_scores: scores})
  end

  @impl true
  def run!(params) do
    {:ok, result} = run(params)
    result
  end

  @impl true
  def suggested_system_prompt,
    do: """
    Eres Alethea, un asistente clínico experto en síntesis terapéutica.
    Genera un snapshot de la sesión para el terapeuta en exactamente 4 líneas numeradas:
    1. ESTADO EMOCIONAL: Resume el tono predominante y su intensidad.
    2. TEMAS TRATADOS: Lista los tópicos clave discutidos.
    3. EVOLUCIÓN: Cambios observados respecto a la sesión anterior (si aplica) o progresión durante el día.
    4. NIVEL DE ATENCIÓN: Elige exactamente uno: Estable / Alerta / Intervención Requerida.
    Responde en español, tono profesional y sin preámbulos.
    """

  @impl true
  def suggested_max_tokens, do: 256

  @impl true
  def supported_providers, do: [:local, :cloud]

  defp do_run(llm, content) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :session_summary}, %{})

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
            chain: :session_summary,
            duration_ms: duration,
            response_length: byte_size(chain.last_message.content)
          }

        {:error, reason} ->
          %{chain: :session_summary, duration_ms: duration, error: inspect(reason)}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, metadata)

    case result do
      {:ok, chain} ->
        {:ok, %{summary: chain.last_message.content, tokens_used: estimate_tokens(content)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(texts, scores) do
    messages = Enum.join(texts, "\n---\n")

    emotions =
      Enum.map_join(scores, ", ", fn %{label: l, score: s} -> "#{l}: #{Float.round(s, 2)}" end)

    "Mensajes de la sesión:\n#{messages}\n\nPerfil emocional: #{emotions}"
  end

  defp estimate_tokens(text), do: div(String.length(text), 4)
end
