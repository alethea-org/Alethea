defmodule Alethea.AI.Chains.PatternProposalChain do
  @moduledoc """
  LangChain chain that turns already-sanitized review-timeline evidence
  into **provisional** functional-analysis pattern suggestions
  (sdd/alethea/issue-195-clinical-review-workbench, GitHub #195, PR4).

  Called only from `AletheaJobs.AIProposalWorker` — never directly from
  the web layer (design D2: clinician-triggered, worker-only generation).
  This module never diagnoses, recommends treatment, resolves conflicts
  between sources, or confirms that cited evidence is true/sufficient —
  its output is always a list of tentative, conditional-tone hypotheses
  (design's AI generation path, spec acceptance criteria for #195).

  Structurally isolated from any confirm/accept/write path: this module
  contains no call into any clinical-note-writing or proposal-status
  -advancing function in `Alethea.ClinicalRecord` (verified by a static
  source scan in `AletheaJobs.AIProposalWorkerTest`), and it never sets
  a `status` value itself — the "pending" status is forced downstream by
  `Alethea.ClinicalRecord.AIProposal.changeset/2`'s `put_change/3`
  (design A6), not by this chain.
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.{LLMConfig, StructuredOutput}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{sanitized_evidence: texts}) when is_list(texts) do
    content = build_prompt(texts)

    case LLMConfig.get_and_build(:pattern_proposal) do
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
    Eres Alethea, un asistente clínico que identifica patrones funcionales
    PROVISIONALES a partir de evidencia clínica ya registrada (citas
    textuales, observaciones del clínico y propuestas previas).

    Reglas estrictas, sin excepción:
    - NUNCA diagnostiques.
    - NUNCA recomiendes un tratamiento o intervención.
    - NUNCA resuelvas conflictos entre distintas fuentes de evidencia.
    - NUNCA confirmes que la evidencia citada es verdadera o suficiente.
    - NUNCA redactes una nota clínica ni uses tono de hecho consumado.
    - Cada patrón es una HIPÓTESIS PROVISIONAL, nunca una conclusión.

    Devuelve `proposals`: una lista de hipótesis de patrón funcional
    (antecedente → comportamiento → consecuencia), cada una redactada en
    tono condicional ("Podría", "Se observa un posible patrón donde..."),
    una hipótesis por elemento de la lista.
    """

    StructuredOutput.with_schema(base, pattern_proposal_schema())
  end

  @impl true
  def suggested_max_tokens, do: 512

  @impl true
  def supported_providers, do: [:local, :cloud]

  @doc false
  @spec pattern_proposal_schema() :: map()
  def pattern_proposal_schema do
    %{
      "type" => "object",
      "properties" => %{
        "proposals" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["proposals"]
    }
  end

  @doc """
  Pure prompt builder — joins the already-sanitized evidence strings.
  Exposed (not `defp`) so it is unit-testable without a live LLM
  endpoint, mirroring the "prefer pure functions" TDD guidance.
  """
  @spec build_prompt([String.t()]) :: String.t()
  def build_prompt(texts) when is_list(texts) do
    "Evidencia clínica registrada en la línea de tiempo:\n" <> Enum.join(texts, "\n---\n")
  end

  @doc """
  Pure response parser: extracts the `proposals` string list from the
  model's JSON response, dropping anything that isn't a plain string.
  Returns `[]` on malformed/missing JSON (a chain failure degrades to
  "no suggestions" rather than raising).
  """
  @spec parse_proposals(String.t()) :: [String.t()]
  def parse_proposals(raw) when is_binary(raw) do
    case StructuredOutput.parse_json_response(raw) do
      {:ok, %{"proposals" => proposals}} when is_list(proposals) ->
        Enum.filter(proposals, &is_binary/1)

      _ ->
        []
    end
  end

  defp do_run(llm, content) do
    start_time = System.monotonic_time(:millisecond)
    :telemetry.execute([:alethea, :ai, :chain, :start], %{chain: :pattern_proposal}, %{})

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
          proposals = parse_proposals(raw)

          meta = %{
            chain: :pattern_proposal,
            duration_ms: duration,
            response_length: byte_size(raw)
          }

          {meta, {:ok, %{proposals: proposals}}}

        {:error, reason} ->
          meta = %{chain: :pattern_proposal, duration_ms: duration, error: inspect(reason)}
          {meta, {:error, reason}}
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, telemetry_meta)
    parsed
  end
end
