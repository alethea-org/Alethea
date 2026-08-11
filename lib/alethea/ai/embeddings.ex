defmodule Alethea.AI.Embeddings do
  @moduledoc """
  Behaviour contract for the embeddings integration that powers the RAG
  (the patient's historia clínica navegable, per ADR-003).

  ## Why this behaviour exists (ADR-002)

  Per `openspec/adr/002-embeddings-hf-multilingue.md`, Alethea uses a
  multilingüe embeddings model (HF Inference API: `intfloat/multilingual-e5-large`
  or `BAAI/bge-m3`) to vectorize patient journaling, transcripciones,
  notas clínicas, etc. The choice between e5 and bge is deferred to
  the concrete adapter change; the behaviour here is the stable
  provider-agnostic interface.

  ## Shape

  - `embed/2` accepts a single text or a list of texts. A single text
    returns `{:ok, [float()]}` (one vector). A list returns
    `{:ok, [[float()]]}` (one vector per input, same order). This
    dual-shape is intentional: it lets the RAG ingest loop call
    `embed/2` without a separate batch endpoint.
  - `model/0` and `dimensions/0` are metadata the pgvector column
    sizing, the RAG retriever, and the psicometría batch pipeline
    rely on. They MUST be stable across calls.

  ## Boundary with the legacy `Alethea.AI.*` namespace

  The v2 behaviour here is parallel: the RAG (future change) calls
  `Alethea.AI.embeddings().embed/2` to vectorize before inserting into
  pgvector.

  ## Adapter discovery

  Domain code dispatches through `Alethea.AI.embeddings/0` (see
  `lib/alethea/ai.ex`), which reads `config :alethea, :ai_embeddings`.
  The default in `:test` env is `Alethea.AI.Embeddings.Fake`.

  ## What concrete implementations are out of scope here

  - `Alethea.AI.Embeddings.HF` → `ai-embeddings-hf-foundation`
  """

  @typedoc "Single-text returns a flat list of floats; batch returns a list of vectors in the same order as the inputs."
  @type vectors :: [float()] | [[float()]]

  @doc """
  Embeds one or many texts.

  - `text :: String.t()` → `{:ok, [float()]}` (one vector).
  - `text :: [String.t()]` → `{:ok, [[float()]]}` (one vector per input,
    in the same order).
  """
  @callback embed(text :: String.t() | [String.t()], opts :: keyword()) ::
              {:ok, vectors()} | {:error, term()}

  @doc "The model identifier, stable across calls."
  @callback model() :: String.t()

  @doc "The vector dimensionality, stable across calls. Used to size the pgvector column."
  @callback dimensions() :: pos_integer()

  defmacro __using__(_opts) do
    quote do
      @behaviour Alethea.AI.Embeddings
    end
  end
end
