defmodule Alethea.ClinicalRecord.Rag.Consultation.Answer do
  @moduledoc """
  Typed result of `Rag.Consultation.answer/4`. `outcome` is exactly one
  of the four values below. Blocking outcomes (`:no_evidence`, `:stale`,
  `:provider_failure`) carry `synthesis: nil` and `sources: []`;
  `pending` is only meaningful for `:stale` (the queued indexing-job
  count). `hypothesis` is additive (ADR-010 §2, #229): non-nil only
  alongside `outcome: :synthesis`. #235 wires `HypothesisPolicy.evaluate/2`
  into `Consultation.Live.synthesize/2`'s `maybe_hypothesis/3`, gated on
  `HypothesisPolicy.interpretive_intent?/1` and fail-silent on any
  hypothesis-path failure — a factual query, or a rejected/raising
  hypothesis attempt, always yields `hypothesis: nil` here.
  """

  alias Alethea.ClinicalRecord.Rag.Consultation.{Hypothesis, Source}

  @type outcome :: :synthesis | :no_evidence | :stale | :provider_failure

  @type t :: %__MODULE__{
          outcome: outcome(),
          synthesis: String.t() | nil,
          sources: [Source.t()],
          pending: non_neg_integer(),
          hypothesis: Hypothesis.t() | nil
        }

  @enforce_keys [:outcome]
  defstruct [:outcome, :synthesis, :hypothesis, sources: [], pending: 0]
end
