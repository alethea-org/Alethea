defmodule Alethea.ClinicalRecord.Rag.Consultation.Live do
  @moduledoc """
  Real `Rag.Consultation` implementation (#232a, hardened in #232b).
  Ordered flow: authz precondition → freshness pre-gate (AD9) →
  retrieval → post-retrieval freshness re-check (AD9, closes the
  enqueue-during-search race) → evidence-threshold filter (AD10) →
  tombstone exclusion (D4 read gate, sdd/clinical-record-retention
  #197) → sanitize-then-synthesize (AD7). Every branch besides the
  authz precondition resolves to a typed `Answer` — no other
  `{:error, _}` ever leaves `answer/4` (AD3).
  """

  @behaviour Alethea.ClinicalRecord.Rag.Consultation

  alias Alethea.Accounts
  alias Alethea.AI.Sanitizer
  alias Alethea.ClinicalRecord.Rag.{Consultation, Retrieval}
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, HypothesisPolicy, Source}
  alias Alethea.ClinicalRecord.Tombstone

  @impl true
  def answer(professional, patient_id, query, opts) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil -> {:error, :unauthorized}
      _patient -> answer_authorized(professional, patient_id, query, opts)
    end
  end

  @impl true
  def open(professional, patient_id) do
    case Retrieval.metadata(professional, patient_id) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, :unavailable} -> {:ok, %{chunk_count: 0, freshness: %{stale?: true, pending: 0}}}
    end
  end

  @doc """
  Pure follow-up resolver, intentionally minimal scope for #232a: uses
  only `role: :professional` history entries, never `role: :assistant`
  content, and never causes a `Source` to be derived from conversation
  text (AD6). Full semantic follow-up resolution is out of scope for
  this task and lands in #233.
  """
  @spec resolve_query(String.t(), [%{role: atom(), content: String.t()}]) :: String.t()
  def resolve_query(query, history) when is_binary(query) and is_list(history), do: query

  defp answer_authorized(professional, patient_id, query, opts) do
    case Retrieval.freshness(patient_id) do
      %{stale?: true, pending: pending} ->
        {:ok, %Answer{outcome: :stale, pending: pending}}

      %{stale?: false} ->
        retrieve_and_answer(professional, patient_id, query, opts)
    end
  end

  defp retrieve_and_answer(professional, patient_id, query, opts) do
    history = Keyword.get(opts, :history, [])
    resolved_query = resolve_query(query, history)

    case Retrieval.search(professional, patient_id, resolved_query, opts) do
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _reason} -> {:ok, %Answer{outcome: :provider_failure}}
      {:ok, envelope} -> handle_envelope(envelope, query)
    end
  end

  defp handle_envelope(%{freshness: %{stale?: true, pending: pending}}, _query) do
    {:ok, %Answer{outcome: :stale, pending: pending}}
  end

  defp handle_envelope(%{results: results}, query) do
    kept =
      results
      |> Enum.filter(&(&1.score >= Consultation.evidence_threshold()))
      |> reject_tombstoned()

    case kept do
      [] -> {:ok, %Answer{outcome: :no_evidence}}
      kept -> synthesize(kept, query)
    end
  end

  # D4 read gate (sdd/clinical-record-retention, GitHub #197): a chunk
  # may still be physically present as an orphan row after its source
  # resource was legally deleted outside the pending-indexing window.
  # `Retrieval.search/4`'s ranking/filtering stays untouched — the
  # exclusion happens here, at query time in `Consultation.Live`, right
  # before evidence ever becomes a `Source`.
  defp reject_tombstoned(results) do
    Enum.reject(results, fn result ->
      Tombstone.for_resource(result.source_resource_type, result.source_resource_id)
    end)
  end

  defp synthesize(kept, query) do
    sources = Source.from_results(kept)
    excerpts = Enum.map(kept, &Sanitizer.sanitize(&1.content))

    case chain().run(%{question: query, excerpts: excerpts}) do
      {:ok, %{synthesis: synthesis}} when is_binary(synthesis) ->
        # AD8 (no-blank-synthesis): a blank prose beside real sources
        # reads as "the record says nothing" — treated as a safe
        # provider_failure, defensively, even if the configured chain
        # (a test mock, in particular) skips its own `parse/1` guard.
        case String.trim(synthesis) do
          "" ->
            {:ok, %Answer{outcome: :provider_failure}}

          trimmed ->
            {:ok,
             %Answer{
               outcome: :synthesis,
               synthesis: trimmed,
               sources: sources,
               hypothesis: maybe_hypothesis(query, excerpts, kept)
             }}
        end

      _other ->
        {:ok, %Answer{outcome: :provider_failure}}
    end
  rescue
    _error -> {:ok, %Answer{outcome: :provider_failure}}
  end

  defp chain,
    do:
      Application.get_env(
        :alethea,
        :clinical_consultation_chain,
        Alethea.AI.Chains.ClinicalConsultationChain
      )

  # PD1/PD2/PD3/PD4 (#235): the sole domain call site for
  # `HypothesisPolicy.interpretive_intent?/1` and `HypothesisPolicy.evaluate/2`
  # (enforced by the Hypothesis Wiring Gate, R9/R11). Own function-level
  # `rescue`, distinct from `synthesize/2`'s — an inner rescue always wins,
  # so no hypothesis defect can ever downgrade a valid synthesis (PD2).
  defp maybe_hypothesis(query, excerpts, kept) do
    if HypothesisPolicy.interpretive_intent?(query) do
      citable = Enum.filter(kept, &(String.trim(&1.content) != ""))

      with false <- citable == [],
           {:ok, %{hypothesis: prose}} <-
             hypothesis_chain().run(%{question: query, excerpts: excerpts}),
           {:ok, hypothesis} <- HypothesisPolicy.evaluate(prose, citable) do
        hypothesis
      else
        _ -> nil
      end
    else
      nil
    end
  rescue
    _error -> nil
  end

  defp hypothesis_chain,
    do:
      Application.get_env(
        :alethea,
        :clinical_hypothesis_chain,
        Alethea.AI.Chains.ClinicalHypothesisChain
      )
end
