defmodule Alethea.AI.Embeddings.Fake do
  @moduledoc """
  No-op embeddings adapter for the `:test` and `:dev` environments.

  Implements the `Alethea.AI.Embeddings` behaviour with deterministic,
  zero-network responses. `embed/2` returns a 1024-dimensional,
  non-zero, input-derived vector (single) or a list of such vectors
  (batch) — matching `BAAI/bge-m3`'s output shape (ADR-002). The model
  and dimensions are pinned so the pgvector column size can be
  computed without the real provider.

  ## Why deterministic AND non-zero

  Tests that exercise the RAG ingest loop need a stable shape to
  assert against, and the `clinical_record_rag_chunks.embedding`
  column is `vector(1024)` (`sdd/clinical-rag-projection`, GitHub
  #196): a 1-dim all-zero stub cannot enter that column, and pgvector
  cosine `<=>` on a zero vector is NaN. Each vector is derived from a
  hash of the input text so identical text always yields the identical
  vector (determinism), and different text yields a different vector
  (so ingest/ranking tests are not accidentally trivial).

  ## Production swap

  The production adapter is `Alethea.AI.Embeddings.Ollama`, scoped to
  the `ai-embeddings-hf-foundation` change (serving BGE-M3 locally
  per ADR-002, revised). The swap happens in
  `config :alethea, :ai_embeddings, Alethea.AI.Embeddings.Ollama` —
  this module's surface stays stable.
  """

  use Alethea.AI.Embeddings

  @dimensions 1024

  @impl true
  def embed(text, _opts) when is_binary(text) do
    {:ok, vector_for(text)}
  end

  def embed(texts, _opts) when is_list(texts) do
    {:ok, Enum.map(texts, &vector_for/1)}
  end

  @impl true
  def model, do: "fake-embeddings-bge-m3"

  @impl true
  def dimensions, do: @dimensions

  # Deterministic, input-derived, non-zero 1024-dim vector. Each
  # dimension is the hash of `{text, index}` folded into [-1.0, 1.0)
  # via `:erlang.phash2/2` — cheap, stable across the BEAM's lifetime,
  # and does not require Nx/random state.
  defp vector_for(text) do
    seed = :erlang.phash2(text)

    Enum.map(0..(@dimensions - 1), fn index ->
      :erlang.phash2({seed, index}, 2_000_001) / 1_000_000.0 - 1.0
    end)
  end
end
