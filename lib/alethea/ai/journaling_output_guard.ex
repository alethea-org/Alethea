defmodule Alethea.AI.JournalingOutputGuard do
  @moduledoc """
  Decides whether a generated journaling reply may be shown to a patient
  (#392).

  The check is purely lexical and local: the reply is normalized with
  `Alethea.AI.ClinicalSafetyPatterns.normalize/1` and scanned with that
  catalog's existing diagnostic and prescriptive patterns. No model or
  classifier is called.

  The catalog is deliberately broad: a reply that merely mentions
  medication or a diagnosis while redirecting the patient to their
  therapist is blocked too. Trigger context permits prescriptive wording
  but never bypasses the diagnostic check.
  """

  alias Alethea.AI.ClinicalSafetyPatterns

  @type block_reason :: :diagnostic | :prescriptive

  @doc """
  Returns `:ok` when `reply` passes the lexical checks, otherwise
  `{:blocked, reason}`. Diagnostic language is always blocked and takes
  precedence. Prescriptive language is allowed only in trigger context.
  """
  @spec check(String.t(), :journaling | :trigger) :: :ok | {:blocked, block_reason()}
  def check(reply, context \\ :journaling)

  def check(reply, context) when is_binary(reply) and context in [:journaling, :trigger] do
    normalized = ClinicalSafetyPatterns.normalize(reply)

    cond do
      matches_any?(normalized, ClinicalSafetyPatterns.diagnostic_patterns()) ->
        {:blocked, :diagnostic}

      context == :journaling and
          matches_any?(normalized, ClinicalSafetyPatterns.prescriptive_patterns()) ->
        {:blocked, :prescriptive}

      true ->
        :ok
    end
  end

  defp matches_any?(text, patterns), do: Enum.any?(patterns, &Regex.match?(&1, text))
end
