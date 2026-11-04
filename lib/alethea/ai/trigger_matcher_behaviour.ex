defmodule Alethea.AI.TriggerMatcherBehaviour do
  @moduledoc """
  Port for reactive-trigger matching (#448).

  Given the sanitized text of one patient burst and the patient's eligible
  reactive triggers, an adapter returns how likely each trigger's condition
  is present in that text — one call per burst, a single request.

  Each candidate carries only the trigger id and its (sanitized) condition
  text: no embeddings, no clinical record, nothing beyond the burst text.

  The result maps each trigger id to a probability in `0.0..1.0`. Ids the
  adapter omits are treated as "no match"; selection and the threshold are
  the caller's concern, never the adapter's.
  """

  @type candidate :: %{id: binary(), condition: String.t()}
  @type probabilities :: %{optional(binary()) => float()}

  @callback match(String.t(), [candidate()]) :: {:ok, probabilities()} | {:error, term()}
end
