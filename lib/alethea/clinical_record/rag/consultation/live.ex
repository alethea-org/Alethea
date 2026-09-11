defmodule Alethea.ClinicalRecord.Rag.Consultation.Live do
  @moduledoc """
  Real `Rag.Consultation` implementation (#232a): authorize (before any
  retrieval) → freshness pre-gate → fresh full-history retrieval every
  turn → post-retrieval freshness re-check (AD9 race) → evidence
  threshold filter → grounded synthesis. `resolve_query/2` only resolves
  follow-up phrasing (AD6/AD11); history is NEVER sent to the chain as
  evidence.
  """

  @behaviour Alethea.ClinicalRecord.Rag.Consultation

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.AI.Sanitizer
  alias Alethea.ClinicalRecord.Rag.{Consultation, Retrieval}
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Source}

  @impl true
  def answer(%Professional{} = professional, patient_id, query, opts)
      when is_binary(patient_id) and is_binary(query) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        {:error, :unauthorized}

      _patient ->
        freshness = Retrieval.freshness(patient_id)

        if freshness.stale? do
          {:ok, %Answer{outcome: :stale, pending: freshness.pending}}
        else
          history = Keyword.get(opts, :history, [])
          retrieve_and_synthesize(professional, patient_id, query, history, opts)
        end
    end
  end

  @impl true
  def open(professional, patient_id) do
    case Retrieval.metadata(professional, patient_id) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  # Pure — resolves a follow-up phrasing into a standalone query using
  # only the professional's own prior turns. Follow-up resolution is
  # deferred (AD6/AD11): this slice returns `query` unchanged, so every
  # turn retrieves fresh on the raw text and conversation history is
  # never counted as, or turned into, evidence.
  @doc false
  @spec resolve_query(String.t(), [map()]) :: String.t()
  def resolve_query(query, history) when is_binary(query) and is_list(history) do
    _professional_turns = Enum.filter(history, &(&1[:role] == :professional))
    query
  end

  defp retrieve_and_synthesize(professional, patient_id, query, history, opts) do
    resolved_query = resolve_query(query, history)

    case Retrieval.search(professional, patient_id, resolved_query, opts) do
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _reason} -> {:ok, provider_failure_answer()}
      {:ok, envelope} -> handle_envelope(envelope, query)
    end
  end

  defp handle_envelope(%{freshness: %{stale?: true, pending: pending}}, _query) do
    {:ok, %Answer{outcome: :stale, pending: pending}}
  end

  defp handle_envelope(%{results: results}, query) do
    kept = Enum.filter(results, &(&1.score >= Consultation.evidence_threshold()))

    case kept do
      [] -> {:ok, %Answer{outcome: :no_evidence}}
      _non_empty -> synthesize(kept, query)
    end
  end

  defp synthesize(kept, query) do
    sources = Source.from_results(kept)
    excerpts = Enum.map(kept, &Sanitizer.sanitize(&1.content))

    case run_chain(query, excerpts) do
      {:ok, %{synthesis: synthesis}} ->
        {:ok, %Answer{outcome: :synthesis, synthesis: synthesis, sources: sources}}

      {:error, _reason} ->
        {:ok, provider_failure_answer()}
    end
  end

  # The chain is a swappable, config-selected boundary — a crash there
  # must never bring down the caller; it is a safe `:provider_failure`,
  # same as any other synthesis error (AD8-adjacent).
  defp run_chain(question, excerpts) do
    chain().run(%{question: question, excerpts: excerpts})
  rescue
    _exception -> {:error, :chain_crashed}
  end

  defp provider_failure_answer, do: %Answer{outcome: :provider_failure}

  defp chain,
    do:
      Application.get_env(
        :alethea,
        :clinical_consultation_chain,
        Alethea.AI.Chains.ClinicalConsultationChain
      )
end
