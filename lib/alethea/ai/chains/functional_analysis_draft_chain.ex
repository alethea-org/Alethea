defmodule Alethea.AI.Chains.FunctionalAnalysisDraftChain do
  @moduledoc """
  Turns already-sanitized review-timeline evidence into a draft
  eleven-field E-O-R-C functional analysis for the psychologist to
  review and edit (sdd/eorc-draft-chain-316, GitHub #316).

  `:local`-only (decrypted clinical narrative never leaves the box).
  Input shape mirrors `PatternProposalChain`, not `ClinicalHypothesisChain`'s
  `%{question:, excerpts:}` (AD4): `run(%{sanitized_evidence: texts})`
  takes a plain list of sanitized evidence strings — no separate
  target-behavior parameter. A future caller (#319) prepends the target
  behavior's description as the first evidence entry if anchoring the
  draft to a specific behavior is desired.

  Never diagnoses, never recommends treatment, never writes to the
  clinical-record store: `run/1` returns only `{:ok, draft_map}` or
  `{:error, term}`. `draft_map` is string-keyed (matching
  `FunctionalAnalysisContent.new/1`'s contract) and contains only the
  fields the model successfully populated (D4, partial-tolerant). A
  populated field whose text matches a diagnostic/prescriptive lexical
  pattern is blanked to `""` instead of rejecting the whole response
  (D3) — present-but-empty is distinguishable from never-populated
  (absent).
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.{ClinicalSafetyPatterns, LLMConfig, StructuredOutput}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @eorc_fields [
    "antecedents_distal",
    "antecedents_immediate",
    "organism_sleep",
    "organism_pain_or_discomfort",
    "organism_hunger_or_nutrition",
    "organism_learning_history",
    "response_physiological",
    "response_cognitive",
    "response_motor",
    "consequences_short_term",
    "consequences_long_term"
  ]

  @impl true
  def run(%{sanitized_evidence: texts}) when is_list(texts) do
    content = build_prompt(texts)

    case LLMConfig.get_and_build(:functional_analysis_draft) do
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
    Eres Alethea, un asistente clínico. A partir de la evidencia clínica ya registrada y saneada que se te entrega, produces un BORRADOR de análisis funcional E-O-R-C para que el psicólogo lo revise y edite. No es un informe ni una conclusión.

    Reglas estrictas, sin excepción:
    - NUNCA diagnostiques: no nombres trastornos, cuadros clínicos, ni criterios DSM/CIE.
    - NUNCA recomiendes tratamiento, medicación, derivación ni intervención.
    - NUNCA uses tono de hecho consumado.
    - NUNCA completes con conocimiento general: usa solo la evidencia entregada.

    Si la evidencia no cubre un campo, devuelve "" (cadena vacía) para ese campo.

    Campos a completar (glosario):
    - antecedents_distal: antecedentes distales, factores lejanos en el tiempo que predisponen la conducta.
    - antecedents_immediate: antecedentes inmediatos, lo que ocurre justo antes de la conducta.
    - organism_sleep: variable organísmica de sueño.
    - organism_pain_or_discomfort: variable organísmica de dolor o malestar físico.
    - organism_hunger_or_nutrition: variable organísmica de hambre o estado nutricional.
    - organism_learning_history: variable organísmica de historia de aprendizaje relevante.
    - response_physiological: respuesta fisiológica observada.
    - response_cognitive: respuesta cognitiva observada (pensamientos, interpretaciones).
    - response_motor: respuesta motora observada (conducta manifiesta).
    - consequences_short_term: consecuencias a corto plazo de la conducta.
    - consequences_long_term: consecuencias a largo plazo de la conducta.

    No completes ningún campo de notas previas: ese campo no forma parte de este borrador.
    """

    StructuredOutput.with_schema(base, functional_analysis_schema())
  end

  @impl true
  def suggested_max_tokens, do: 1024

  @impl true
  def supported_providers, do: [:local]

  @doc false
  @spec eorc_fields() :: [String.t()]
  def eorc_fields, do: @eorc_fields

  @doc false
  @spec functional_analysis_schema() :: map()
  def functional_analysis_schema do
    properties = Map.new(@eorc_fields, &{&1, %{"type" => "string"}})

    %{
      "type" => "object",
      "properties" => properties,
      "required" => @eorc_fields
    }
  end

  @doc """
  Pure prompt builder — numbers the already-sanitized evidence strings.
  Carries no chunk/resource/target-behavior identifiers — the model has
  no channel to fabricate a citation.
  """
  @spec build_prompt([String.t()]) :: String.t()
  def build_prompt(texts) when is_list(texts) do
    numbered =
      texts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {text, index} -> "#{index}. #{text}" end)

    "Evidencia clínica registrada en la línea de tiempo:\n" <> numbered
  end

  @doc """
  Pure response parser (D3 gate + D4 partial contract): fence-stripped
  decode → opt-in `properties` unwrap → keep only known E-O-R-C keys
  with a non-blank binary value (everything else stays absent) → blank
  any surviving field matching a diagnostic/prescriptive pattern to
  `""` (siblings untouched) → zero surviving fields is
  `{:error, :unparseable}`.
  """
  @spec parse(String.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, :unparseable}
  def parse(raw) when is_binary(raw) do
    with {:ok, decoded} <- StructuredOutput.parse_json_response(raw) do
      fields =
        decoded
        |> StructuredOutput.unwrap_schema_echo()
        |> extract_fields()

      if map_size(fields) > 0 do
        {:ok, fields}
      else
        {:error, :unparseable}
      end
    else
      _error -> {:error, :unparseable}
    end
  end

  defp extract_fields(decoded) when is_map(decoded) do
    Enum.reduce(@eorc_fields, %{}, fn field, acc ->
      case Map.get(decoded, field) do
        value when is_binary(value) ->
          trimmed = String.trim(value)

          if trimmed == "" do
            acc
          else
            Map.put(acc, field, blank_if_flagged(trimmed))
          end

        _other ->
          acc
      end
    end)
  end

  defp extract_fields(_other), do: %{}

  defp blank_if_flagged(text) do
    if flagged?(text), do: "", else: text
  end

  defp flagged?(text) do
    normalized = ClinicalSafetyPatterns.normalize(text)

    Enum.any?(
      ClinicalSafetyPatterns.diagnostic_patterns() ++
        ClinicalSafetyPatterns.prescriptive_patterns(),
      &Regex.match?(&1, normalized)
    )
  end

  defp do_run(llm, content) do
    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:alethea, :ai, :chain, :start],
      %{chain: :functional_analysis_draft},
      %{}
    )

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
            chain: :functional_analysis_draft,
            duration_ms: duration,
            response_length: byte_size(raw)
          }

          {meta, parse(raw)}

        {:error, reason} ->
          meta = %{
            chain: :functional_analysis_draft,
            duration_ms: duration,
            error: inspect(reason)
          }

          {meta, {:error, reason}}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, telemetry_meta)
    parsed
  end
end
