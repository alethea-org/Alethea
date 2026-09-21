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
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Source}
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
  B2 follow-up resolver (#233): the B1 slot exists only to *label* the
  turn ("turno N → turno N+1") and carry server-derived `source_ref`s for
  deduplication. It is NOT treated as evidence: the user-typed query is
  passed verbatim to `Retrieval.search/4`, never expanded, never rewritten
  with prior question text or assistant prose. The legacy `resolve_query/2`
  arity is preserved for the #232a test fixture and as a structural guard
  that conversation history (typed in the caller) cannot reach the chain
  — see `LiveFollowupTest`.
  """
  @spec resolve_query(String.t(), [%{role: atom(), content: String.t()}]) :: String.t()
  def resolve_query(query, history) when is_binary(query) and is_list(history), do: query

  @doc """
  B2-aware resolver (#233): the typed `FollowupState` only contributes
  metadata (current turn index + last-turn server-derived refs). It is
  impossible, by type, for it to feed excerpts or synthesis into the
  search query.
  """
  @spec resolve_query(String.t(), map() | nil, non_neg_integer()) :: String.t()
  def resolve_query(query, followup_state, turn_index)
      when is_binary(query) and (is_nil(followup_state) or is_map(followup_state)) and
             is_integer(turn_index) and turn_index >= 0 do
    _ = followup_state
    _ = turn_index
    query
  end

  # Cross-patient guard extracted from `answer_authorized/4`. The B1 slot
  # is patient-scoped; if the slot's `patient_id` does not match the one
  # we are about to retrieve, refuse the turn as `{:error, :unauthorized}`.
  defp authorize_followup_slot(nil, _patient_id), do: :ok

  defp authorize_followup_slot(%{patient_id: patient_id}, patient_id), do: :ok

  defp authorize_followup_slot(%{patient_id: other}, _patient_id)
       when is_binary(other) and other != "" do
    {:error, :unauthorized}
  end

  defp authorize_followup_slot(%{}, _patient_id), do: :ok

  defp answer_authorized(professional, patient_id, query, opts) do
    followup_state = Keyword.get(opts, :followup_state)
    _turn_index = Keyword.get(opts, :turn_index, 0)

    case authorize_followup_slot(followup_state, patient_id) do
      {:error, :unauthorized} ->
        {:error, :unauthorized}

      :ok ->
        case Retrieval.freshness(patient_id) do
          %{stale?: true, pending: pending} ->
            {:ok, %Answer{outcome: :stale, pending: pending}}

          %{stale?: false} ->
            retrieve_and_answer(professional, patient_id, query, followup_state, opts)
        end
    end
  end

  defp retrieve_and_answer(professional, patient_id, query, followup_state, opts) do
    _ = followup_state
    # B2 (#233): the query the user typed is the query we retrieve on.
    # Prior conversation text — whether it sits in `opts[:history]` or in
    # the B1 slot — is never expanded into the search query and never
    # reaches the chain as context. `resolve_query/3` is the typed seam
    # that pins this: only the B1 struct (which cannot contain excerpts
    # by type) is allowed as a desambiguation hint.
    resolved_query = resolve_query(query, followup_state, Keyword.get(opts, :turn_index, 0))

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
          "" -> {:ok, %Answer{outcome: :provider_failure}}
          trimmed -> {:ok, %Answer{outcome: :synthesis, synthesis: trimmed, sources: sources}}
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
end
