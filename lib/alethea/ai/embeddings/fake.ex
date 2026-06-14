defmodule Alethea.AI.Embeddings.Fake do
  @moduledoc """
  No-op embeddings adapter for the `:test` and `:dev` environments.

  Implements the `Alethea.AI.Embeddings` behaviour with deterministic,
  zero-network responses. `embed/2` returns a vector of `[0.0]`
  (single) or a list of `[0.0]` vectors (batch). The model and
  dimensions are pinned so the pgvector column size can be computed
  without the real provider.

  ## Why deterministic

  Tests that exercise the RAG ingest loop or the psicometría pipeline
  need a stable shape to assert against. Real HF Inference responses
  would change between runs; the Fake pins both the vector content
  and the metadata.

  ## Production swap

  The production adapter is `Alethea.AI.Embeddings.HF`, scoped to
  the `ai-embeddings-hf-foundation` change. The swap happens in
  `config :alethea, :ai_embeddings, Alethea.AI.Embeddings.HF` —
  this module's surface stays stable.
  """

  use Alethea.AI.Embeddings

  @impl true
  def embed(text, _opts) when is_binary(text) do
    {:ok, [0.0]}
  end

  def embed(texts, _opts) when is_list(texts) do
    {:ok, List.duplicate([0.0], length(texts))}
  end

  @impl true
  def model, do: "fake-embeddings"

  @impl true
  def dimensions, do: 1
end
