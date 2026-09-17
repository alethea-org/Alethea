defmodule Alethea.ClinicalRecord.Rag.Consultation.Hypothesis do
  @moduledoc """
  A revisable "Hipótesis para revisar" (ADR-010 §2): an interpretive
  reading of a pattern or relationship across cited evidence, never a
  diagnosis nor a treatment recommendation. Cannot exist without a
  `statement`, at least one server-derived `Source`, and the mandatory
  `disclaimer` — `HypothesisPolicy.evaluate/2` is the sole constructor.
  """

  alias Alethea.ClinicalRecord.Rag.Consultation.Source

  @disclaimer "Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica."

  @type t :: %__MODULE__{
          statement: String.t(),
          # non-empty by construction; HypothesisPolicy.evaluate/2 enforces it at runtime
          sources: [Source.t(), ...],
          disclaimer: String.t()
        }

  @enforce_keys [:statement, :sources, :disclaimer]
  defstruct [:statement, :sources, :disclaimer]

  @doc "The mandatory, server-owned disclaimer (D2). Never LLM-authored."
  @spec disclaimer() :: String.t()
  def disclaimer, do: @disclaimer
end
