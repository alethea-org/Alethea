defmodule Alethea.AI.Embeddings.Disabled do
  @moduledoc """
  Embeddings adapter for a deployment where the capability is explicitly
  switched off (issue #402).

  Production wires this module into the `:ai_embeddings` slot when
  `EMBEDDINGS_ENABLED=false`, so "disabled" is a configured state instead
  of an unset key that raises. `embed/2` returns `{:error, :disabled}` and
  never a vector, so nothing is indexed or retrieved from a capability
  that is off. `Alethea.AI.enabled?(:ai_embeddings)` answers the question
  without calling the adapter.
  """

  use Alethea.AI.Embeddings

  @impl true
  def embed(_text, _opts), do: {:error, :disabled}

  @impl true
  def model, do: "disabled"

  # Metadata only: `embed/2` never returns a vector to size. The value
  # matches the pgvector column so a caller reading it cannot derive a
  # wrong dimension.
  @impl true
  def dimensions, do: 1024
end
