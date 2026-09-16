defmodule Alethea.AI.Chains.ClinicalHypothesisChain do
  @moduledoc """
  Interpretive hypothesis generation for the clinical consultation chat
  (sdd/grounded-chat-229-hypothesis-policy, GitHub #229b).

  `:local`-only sibling of `ClinicalConsultationChain`, byte-identical in
  shape: given an already-retrieved, already-server-selected set of
  sanitized excerpts and a question, it returns
  `{:ok, %{hypothesis: prose}}` or `{:error, term}`. It produces only
  prose — it never sees `chunk_id`/`resource_id`/`target_behavior_id`, so
  it cannot fabricate a citation; it never writes the mandatory D2
  disclaimer; and it never constructs a typed `Hypothesis` value object
  (that is `HypothesisPolicy.evaluate/2`'s sole responsibility).

  Local-only (D2 / AD5): decrypted clinical narrative must never leave the
  box, so `supported_providers/0` is `[:local]` and no external-provider
  path exists. On empty / malformed / unparseable model output `parse/1`
  returns `{:error, :unparseable}` (AD8) — it never degrades to blank
  prose, which would read as an endorsed conclusion beside real sources.
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.{LLMConfig, StructuredOutput}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{question: question, excerpts: excerpts})
      when is_binary(question) and is_list(excerpts) do
    content = build_prompt(%{question: question, excerpts: excerpts})

    case LLMConfig.get_and_build(:consultation_hypothesis) do
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
    Eres Alethea, un asistente clínico. Propones UNA hipótesis interpretativa breve, para que el psicólogo la revise, ÚNICAMENTE a partir de los fragmentos de evidencia clínica numerados que se te entregan.

    Una hipótesis es una lectura tentativa de un patrón o una relación entre los fragmentos. NO es un diagnóstico ni una recomendación terapéutica.

    Regla estricta, sin excepción: no nombres trastornos ni cuadros clínicos, no indiques tratamiento, medicación ni derivación, no completes con conocimiento general; si los fragmentos no permiten una hipótesis, dilo.

    - Usa solo la información contenida en los fragmentos.
    - Formula en modo tentativo ("podría", "es posible que"), nunca como conclusión.
    - No enumeres ni cites fuentes: devuelve solo el enunciado de la hipótesis.
    - No escribas ninguna advertencia ni descargo de responsabilidad: el servidor lo añade.
    """

    StructuredOutput.with_schema(base, hypothesis_schema())
  end

  @impl true
  def suggested_max_tokens, do: 384

  @impl true
  def supported_providers, do: [:local]

  @doc false
  @spec hypothesis_schema() :: map()
  def hypothesis_schema do
    %{
      "type" => "object",
      "properties" => %{"hypothesis" => %{"type" => "string"}},
      "required" => ["hypothesis"]
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
  Pure response parser: extracts the `hypothesis` prose from the model's
  JSON response. Returns `{:error, :unparseable}` on malformed JSON, a
  missing key, or an empty/blank string — never a blank hypothesis (AD8).
  """
  @spec parse(String.t()) :: {:ok, %{hypothesis: String.t()}} | {:error, :unparseable}
  def parse(raw) when is_binary(raw) do
    case StructuredOutput.parse_json_response(raw) do
      {:ok, %{"hypothesis" => hypothesis}} when is_binary(hypothesis) ->
        trimmed = String.trim(hypothesis)

        if trimmed == "" do
          {:error, :unparseable}
        else
          {:ok, %{hypothesis: trimmed}}
        end

      _ ->
        {:error, :unparseable}
    end
  end

  defp do_run(llm, content) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :clinical_hypothesis}, %{})

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
            chain: :clinical_hypothesis,
            duration_ms: duration,
            response_length: byte_size(raw)
          }

          {meta, parse(raw)}

        {:error, reason} ->
          meta = %{chain: :clinical_hypothesis, duration_ms: duration, error: inspect(reason)}
          {meta, {:error, reason}}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, telemetry_meta)
    parsed
  end
end
