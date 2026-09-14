defmodule Alethea.ClinicalRecord.Rag.Consultation do
  @moduledoc """
  Grounded clinical consultation contract (#226): a behaviour plus a
  dispatcher facade over a swappable implementation
  (`config :alethea, :clinical_consultation`, default `__MODULE__.Live`).
  `answer/4` returns a typed `Answer` on the `{:ok, _}` path or the
  precondition `{:error, :unauthorized}`; `open/2` is the mount-time
  authorization + idle-metadata check. `evidence_threshold/0` owns the
  sufficiency threshold (config `:consultation_evidence_threshold`,
  default `0.35`).
  """

  alias Alethea.Accounts.Professional
  alias Alethea.ClinicalRecord.Rag.Consultation.Answer

  @default_evidence_threshold 0.35

  @type metadata :: %{chunk_count: non_neg_integer(), freshness: map()}

  @callback answer(Professional.t(), Ecto.UUID.t(), String.t(), keyword()) ::
              {:ok, Answer.t()} | {:error, :unauthorized}

  @callback open(Professional.t(), Ecto.UUID.t()) ::
              {:ok, metadata()} | {:error, :unauthorized}

  @spec answer(Professional.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Answer.t()} | {:error, :unauthorized}
  def answer(professional, patient_id, query, opts \\ []),
    do: impl().answer(professional, patient_id, query, opts)

  @spec open(Professional.t(), Ecto.UUID.t()) :: {:ok, metadata()} | {:error, :unauthorized}
  def open(professional, patient_id), do: impl().open(professional, patient_id)

  @spec evidence_threshold() :: float()
  def evidence_threshold,
    do:
      Application.get_env(:alethea, :consultation_evidence_threshold, @default_evidence_threshold)

  defp impl, do: Application.get_env(:alethea, :clinical_consultation, __MODULE__.Live)
end
