defmodule AletheaWeb.GroundedChat.SourceCitation do
  @moduledoc """
  Adapts `Alethea.ClinicalRecord.Rag.Consultation.Source.t()` (#226a)
  into `Alethea.ClinicalRecord.Rag.Citation.t()` (#230), so both the
  *Síntesis* (#234) and *Hipótesis* (#231) panels can render through the
  shared `AletheaWeb.CoreComponents.citation/1`/`citation_list/1` — one
  renderer, no divergent DOM shape per source type.

  Promoted (#235c) from `AletheaWeb.GroundedChat.HypothesisPanel`'s
  private `source_to_citation/1`, which anticipated exactly this
  hand-off: "si #235 termina necesitando la misma conversión al
  unificar con Síntesis, promoverlo a público ahí, no antes."

  Does not use `Citation.from_retrieval_result/1` ("the only
  constructor" in `citation.ex`) — that constructor expects the raw
  retrieval-envelope map, not an already-built `%Source{}`. This builds
  the struct directly instead, the only way to adapt without touching
  `citation.ex`.

  Rejects an empty excerpt the same way `from_retrieval_result/1` does:
  neither `HypothesisPolicy.evaluate/2` nor `Source.from_results/1`
  guarantees a non-empty excerpt per element — this is the only real
  "never cite unverifiable content" guarantee left in this chain.

  `score` and `chunk_index` stay `nil` — `Source.t()` doesn't carry
  them, and `citation/1` never renders them.
  """

  alias Alethea.ClinicalRecord.Rag.Citation
  alias Alethea.ClinicalRecord.Rag.Consultation.Source

  @doc """
  Converts a single `%Source{}` into a `%Citation{}`.

  Raises `ArgumentError` if the source's excerpt is empty.
  """
  @spec source_to_citation(Source.t()) :: Citation.t()
  def source_to_citation(%Source{} = source) do
    if source.excerpt == "" do
      raise ArgumentError, "Source has empty excerpt — empty cite cannot be verified"
    end

    short_chunk_id =
      source.reference.chunk_id
      |> to_string()
      |> String.slice(0, 8)

    %Citation{
      source_ref: "#{source.reference.resource_type}/#{short_chunk_id}",
      kind: source.kind,
      occurred_at: source.occurred_at,
      excerpt: source.excerpt,
      score: nil,
      chunk_index: nil
    }
  end
end
