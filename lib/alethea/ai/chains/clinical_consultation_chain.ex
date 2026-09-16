defmodule Alethea.AI.Chains.ClinicalConsultationChain do
  @moduledoc """
  Grounded synthesis for the clinical consultation chat
  (sdd/grounded-clinical-chat-initial, GitHub #223, PR #226b).

  Serves `Alethea.ClinicalRecord.Rag.Consultation`: given an
  already-retrieved, already-server-selected set of sanitized excerpts and
  a question, it returns `{:ok, %{synthesis: prose}}` or `{:error, term}`.
  It never returns, selects, ranks, or fabricates a source list.

  Local-only (D2 / AD5): decrypted clinical narrative must never leave the
  box, so `supported_providers/0` is `[:local]` and no external-provider
  path exists. On empty / malformed / unparseable model output `parse/1`
  returns `{:error, :unparseable}` (AD8) — it never degrades to blank
  prose, which would read as a false clinical negative beside real sources.
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.{LLMConfig, StructuredOutput}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{question: question, excerpts: excerpts})
      when is_binary(question) and is_list(excerpts) do
    content = build_prompt(%{question: question, excerpts: excerpts})

    case LLMConfig.get_and_build(:consultation_synthesis) do
      {:ok, _config, llm} -> do_run(llm, content)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run!(params) do
    {:ok, result} = run(params)
    result
  end

  @impl true
  def suggested_system_prompt do
    base = """
    Eres Alethea, un asistente clínico. Redactas una síntesis en prosa ÚNICAMENTE a partir de los fragmentos de evidencia clínica numerados que se te entregan.

    Regla estricta, sin excepción: no diagnostiques, no recomiendes tratamiento, no completes con conocimiento general; si los fragmentos no alcanzan, dilo.

    - Usa solo la información contenida en los fragmentos.
    - No inventes, no supongas, no añadas datos externos.
    - No enumeres ni cites fuentes: devuelve solo la síntesis.
    """

    StructuredOutput.with_schema(base, synthesis_schema())
  end

  @impl true
  def suggested_max_tokens, do: 512

  @impl true
  def supported_providers, do: [:local]

  @doc false
  @spec synthesis_schema() :: map()
  def synthesis_schema do
    %{
      "type" => "object",
      "properties" => %{"synthesis" => %{"type" => "string"}},
      "required" => ["synthesis"]
    }
  end

  @doc """
  Pure prompt builder: the question plus the already-sanitized excerpts,
  numbered. Carries no chunk/resource identifiers — the model has no
  channel to name a source.
  """
  @spec build_prompt(%{question: String.t(), excerpts: [String.t()]}) :: String.t()
  def build_prompt(%{question: question, excerpts: excerpts})
      when is_binary(question) and is_list(excerpts) do
    numbered =
      excerpts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {excerpt, index} -> "#{index}. #{excerpt}" end)

    """
    Pregunta del profesional:
    #{question}

    Fragmentos de evidencia clínica (usa solo estos):
    #{numbered}
    """
  end

  @doc """
  Pure response parser: extracts the `synthesis` prose from the model's
  JSON response. Returns `{:error, :unparseable}` on malformed JSON, a
  missing key, or an empty/blank string — never a blank synthesis (AD8).
  """
  @spec parse(String.t()) :: {:ok, %{synthesis: String.t()}} | {:error, :unparseable}
  def parse(raw) when is_binary(raw) do
    case StructuredOutput.parse_json_response(raw) do
      {:ok, %{"synthesis" => synthesis}} when is_binary(synthesis) ->
        trimmed = String.trim(synthesis)

        if trimmed == "" do
          {:error, :unparseable}
        else
          {:ok, %{synthesis: trimmed}}
        end

      _ ->
        {:error, :unparseable}
    end
  end

  defp do_run(llm, content) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :clinical_consultation}, %{})

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
          raw = chain.last_message.content || ""

          meta = %{
            chain: :clinical_consultation,
            duration_ms: duration,
            response_length: byte_size(raw)
          }

          {meta, parse(raw)}

        {:error, reason} ->
          meta = %{chain: :clinical_consultation, duration_ms: duration, error: inspect(reason)}
          {meta, {:error, reason}}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, telemetry_meta)
    parsed
  end
end
