defmodule Alethea.AI.JournalingOutputGuard do
  @moduledoc """
  Decides whether a generated journaling reply may be shown to a patient
  (#392).

  The check is purely lexical and local: the reply is normalized with
  `Alethea.AI.ClinicalSafetyPatterns.normalize/1` and scanned with that
  catalog's existing diagnostic and prescriptive patterns. No model or
  classifier is called.

  The catalog is deliberately broad — a reply that merely mentions
  medication or a diagnosis while redirecting the patient to their
  therapist is blocked too. That is the intended, conservative outcome:
  a blocked reply costs the patient one generic question, an unblocked
  one could put clinical language in front of them.
  """

  alias Alethea.AI.ClinicalSafetyPatterns

  @type block_reason :: :diagnostic | :prescriptive

  @doc """
  Returns `:ok` when `reply` is free of diagnostic and prescriptive
  language, otherwise `{:blocked, reason}`. Diagnostic language takes
  precedence when both are present.
  """
  @spec check(String.t()) :: :ok | {:blocked, block_reason()}
  def check(reply) when is_binary(reply) do
    normalized = ClinicalSafetyPatterns.normalize(reply)

    cond do
      matches_any?(normalized, ClinicalSafetyPatterns.diagnostic_patterns()) ->
        {:blocked, :diagnostic}

      matches_any?(normalized, ClinicalSafetyPatterns.prescriptive_patterns()) ->
        {:blocked, :prescriptive}

      true ->
        :ok
    end
  end

  defp matches_any?(text, patterns), do: Enum.any?(patterns, &Regex.match?(&1, text))
end
