defmodule Alethea.ClinicalRecord.Rag.Consultation.Source do
  @moduledoc """
  A cited evidence fragment, built server-side from a
  `Rag.Retrieval.search/4` envelope result. `excerpt` is the verbatim
  decrypted chunk content; `reference` is a stable pointer back to the
  originating chunk/resource. The synthesis LLM never produces these —
  `from_results/1` is the only constructor.
  """

  @type reference_map :: %{
          chunk_id: Ecto.UUID.t(),
          resource_type: String.t(),
          resource_id: Ecto.UUID.t(),
          target_behavior_id: Ecto.UUID.t() | nil
        }

  @type t :: %__MODULE__{
          excerpt: String.t(),
          kind: String.t(),
          occurred_at: DateTime.t(),
          reference: reference_map()
        }

  @enforce_keys [:excerpt, :kind, :occurred_at, :reference]
  defstruct [:excerpt, :kind, :occurred_at, :reference]

  @doc """
  Maps each `Rag.Retrieval.search/4` envelope result 1:1 into a
  `%Source{}`, verbatim: `excerpt` from `content`, `kind` from
  `source_resource_type`, `occurred_at` from `source_occurred_at`, and a
  stable `reference` map. Nothing is added, dropped, or reordered.
  """
  @spec from_results([map()]) :: [t()]
  def from_results(results) when is_list(results) do
    Enum.map(results, fn result ->
      %__MODULE__{
        excerpt: result.content,
        kind: result.source_resource_type,
        occurred_at: result.source_occurred_at,
        reference: %{
          chunk_id: result.chunk_id,
          resource_type: result.source_resource_type,
          resource_id: result.source_resource_id,
          target_behavior_id: result.target_behavior_id
        }
      }
    end)
  end
end
