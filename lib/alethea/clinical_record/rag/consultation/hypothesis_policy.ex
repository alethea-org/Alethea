defmodule Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy do
  @moduledoc """
  Pure policy deciding whether a grounded consultation answer may carry
  a revisable "Hipótesis para revisar" (ADR-010 §2). Owns the D1
  interpretive-intent heuristic and the D3 fail-closed lexical gate.
  `evaluate/2` is the sole constructor of `Hypothesis`. Never calls an
  LLM, `Repo`, or any clinical mutation function.
  """

  alias Alethea.AI.ClinicalSafetyPatterns
  alias Alethea.ClinicalRecord.Rag.Consultation.{Hypothesis, Source}

  @type reject_reason ::
          :no_evidence | :empty_statement | :diagnostic_language | :prescriptive_language

  @interpretive_markers [
    # Causal
    "por que",
    "a que se debe",
    "podria deberse",
    "puede deberse",
    "se debe a",
    "que explica",
    "como se explica",
    # Relational
    "que relacion",
    "relacion entre",
    "tiene que ver con",
    "esta relacionado",
    "correlacion",
    "influye",
    "influencia",
    # Pattern
    "patron",
    "tendencia",
    "se repite",
    "recurrente",
    # Interpretive
    "que significa",
    "como interpret",
    "interpretacion",
    "tendria sentido que",
    "hipotesis"
  ]

  @factual_veto_markers [
    "cuando",
    "cuantas veces",
    "cuantos",
    "cuantas",
    "que dijo",
    "que dia",
    "que fecha",
    "en que sesion",
    "quien",
    "lista",
    "enumera",
    "ultima vez"
  ]

  @doc """
  Pure, deterministic classification of Spanish interrogative/relational
  markers on a normalized query. Never calls an LLM or external service.
  A factual veto marker always wins over an interpretive marker (AD2).
  """
  @spec interpretive_intent?(String.t()) :: boolean()
  def interpretive_intent?(text) do
    normalized = normalize(text)

    cond do
      normalized == "" -> false
      Enum.any?(@factual_veto_markers, &String.contains?(normalized, &1)) -> false
      Enum.any?(@interpretive_markers, &String.contains?(normalized, &1)) -> true
      true -> false
    end
  end

  @doc false
  @spec diagnostic_patterns() :: [Regex.t()]
  defdelegate diagnostic_patterns(), to: ClinicalSafetyPatterns

  @doc false
  @spec prescriptive_patterns() :: [Regex.t()]
  defdelegate prescriptive_patterns(), to: ClinicalSafetyPatterns

  @doc """
  The sole constructor of `Hypothesis`. Fixed gate precedence:

    1. `results == []` → `{:reject, :no_evidence}`
    2. blank `candidate_text` → `{:reject, :empty_statement}`
    3. diagnostic pattern match on raw `candidate_text` → `{:reject, :diagnostic_language}`
    4. prescriptive pattern match on raw `candidate_text` → `{:reject, :prescriptive_language}`
    5. otherwise → `{:ok, %Hypothesis{}}`

  The lexical scan runs against `candidate_text` only (normalized),
  BEFORE the disclaimer is attached — never against the assembled
  struct. The D2 disclaimer itself contains "diagnóstico" and
  "recomendación terapéutica"; scanning post-attachment would reject
  every hypothesis (AD5, non-negotiable).
  """
  @spec evaluate(String.t(), [map()]) :: {:ok, Hypothesis.t()} | {:reject, reject_reason()}
  def evaluate(candidate_text, results) when is_list(results) do
    trimmed = String.trim(candidate_text)
    normalized = normalize(trimmed)

    cond do
      results == [] ->
        {:reject, :no_evidence}

      trimmed == "" ->
        {:reject, :empty_statement}

      Enum.any?(ClinicalSafetyPatterns.diagnostic_patterns(), &Regex.match?(&1, normalized)) ->
        {:reject, :diagnostic_language}

      Enum.any?(ClinicalSafetyPatterns.prescriptive_patterns(), &Regex.match?(&1, normalized)) ->
        {:reject, :prescriptive_language}

      true ->
        {:ok,
         %Hypothesis{
           statement: trimmed,
           sources: Source.from_results(results),
           disclaimer: Hypothesis.disclaimer()
         }}
    end
  end

  # Shared normalization for both gates: downcase, accent-fold (keep ñ),
  # collapse whitespace. Delegates to the AD1 catalog (#316) — kept as a
  # private wrapper so this module's existing call sites are unchanged.
  @spec normalize(String.t()) :: String.t()
  defp normalize(text), do: ClinicalSafetyPatterns.normalize(text)
end
