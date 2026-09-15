defmodule Alethea.ClinicalRecord.Rag.Citation do
  @moduledoc """
  Server-derived value object for a single source cited in the grounded
  chat (ADR-010 §3 — "La evidencia y sus citas se derivan de la
  recuperación del paciente, no del contenido previo de la conversación").

  A `Citation` can ONLY be constructed from a server-side
  `Alethea.ClinicalRecord.Rag.Retrieval.result/0` map. There is no
  public way to build one from arbitrary text; the only constructor is
  `from_retrieval_result/1`, which pattern-matches on the map and
  rejects anything missing the four anchors the renderer relies on
  (`chunk_id`, `source_resource_id`, `source_resource_type`, non-empty
  `content`). At render time, `reject_unknown_refs/2` is the safety net
  to drop any cite whose `source_ref` is not in the original server
  envelope — defense-in-depth so a future caller cannot slip a free
  text in via the front door.

  Hand-off:

    * A2 (issue #227) and A4 (issue #234) build the list of citations
      from the result envelopes the contract returns.
    * The component in `AletheaWeb.CoreComponents` (`citation/1`,
      `citation_list/1`) is the only thing that should render them.
    * C3 (issue #231) imports the same component for the Hipótesis
      panel, no divergent rendering; C4 (#235) is the integration
      point that unifies this renderer with the A-chain Síntesis
      surface (and replaces it with `Alethea.ClinicalRecord.Rag.
      Consultation.Source` from #226a as the upstream value type).
  """

  @enforce_keys [:source_ref, :kind, :occurred_at, :excerpt, :score]
  defstruct [:source_ref, :kind, :occurred_at, :excerpt, :score, :chunk_index]

  @type t :: %__MODULE__{
          source_ref: String.t(),
          kind: String.t(),
          occurred_at: DateTime.t(),
          excerpt: String.t(),
          score: float(),
          chunk_index: non_neg_integer()
        }

  @doc """
  Builds a citation from a single retrieval result map (one entry of
  the `results` list `Alethea.ClinicalRecord.Rag.Retrieval.search/4`
  returns). All four required server anchors must be present; the
  excerpt must be non-empty.

  Raises `FunctionClauseError` if the argument is not a map.
  Raises `ArgumentError` if any required key is missing or if the
  excerpt is empty.
  """
  @spec from_retrieval_result(map()) :: t()
  def from_retrieval_result(%{} = result) do
    chunk_id = fetch!(result, :chunk_id)
    source_resource_type = fetch!(result, :source_resource_type)
    source_resource_id = fetch!(result, :source_resource_id)
    content = fetch!(result, :content)
    source_occurred_at = fetch!(result, :source_occurred_at)
    chunk_index = fetch!(result, :chunk_index)
    score = fetch!(result, :score)

    _ = chunk_id

    if content == "" do
      raise ArgumentError,
            "retrieval result has empty :content — empty cite cannot be verified"
    end

    %__MODULE__{
      source_ref: ref(result),
      kind: source_resource_type,
      occurred_at: source_occurred_at,
      excerpt: content,
      score: score,
      chunk_index: chunk_index
    }
  end

  @doc """
  Deterministic reference for a retrieval result. Encodes the
  `source_resource_type` and `chunk_index` so the value is readable in
  the DOM and ARIA; the short `source_resource_id` prefix carries the
  uniqueness guarantee.

  Same input always yields the same `source_ref`. Different
  `source_resource_id` or `chunk_index` yields a different ref.
  """
  @spec ref(map()) :: String.t()
  def ref(%{
        source_resource_type: kind,
        source_resource_id: id,
        chunk_index: chunk_index
      }) do
    short_id = id |> to_string() |> String.slice(0, 8)
    "#{kind}/#{short_id}#chunk-#{chunk_index}"
  end

  @doc """
  Drops every cite whose `source_ref` is not in `allowed_refs` —
  typically the `MapSet` of refs the original server envelope
  produced. Use at the render boundary as a defense-in-depth against
  any cite that did not come from the retrieve call.
  """
  @spec reject_unknown_refs([t()], MapSet.t(String.t())) :: [t()]
  def reject_unknown_refs(citations, %MapSet{} = allowed_refs)
      when is_list(citations) do
    Enum.filter(citations, fn citation ->
      MapSet.member?(allowed_refs, citation.source_ref)
    end)
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "retrieval result is missing required server-derived field :#{key}"
    end
  end
end
