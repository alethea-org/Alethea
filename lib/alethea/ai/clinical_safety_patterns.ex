defmodule Alethea.AI.ClinicalSafetyPatterns do
  @moduledoc """
  Neutral, dependency-free catalog of the Spanish diagnostic/prescriptive
  lexical patterns and their shared text normalization (#316 AD1). Data
  and normalization only — no `evaluate/2`, no reject reasons, no struct
  construction, no decision. Extracted verbatim from
  `Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy`, which
  delegates to this module to preserve its D3 gate behavior unchanged.

  Consumed by `HypothesisPolicy` (delegation) and by
  `Alethea.AI.Chains.FunctionalAnalysisDraftChain` (direct use) — the
  latter is why this catalog lives in `Alethea.AI` rather than in
  `Alethea.ClinicalRecord`: it keeps the chain's structural safety scan
  free of any `Alethea.ClinicalRecord` alias.
  """

  @diagnostic_patterns [
    # diagnóstico, diagnóstica, diagnosticar, diagnosticado
    ~r/\bdiagnostic\w*\b/,
    ~r/\btrastorno\w*\b/,
    ~r/\bpatolog\w*\b/,
    # padece, padecería
    ~r/\bpadec\w*\b/,
    ~r/\bsufre de\b/,
    ~r/\bcumple criterios\b/,
    ~r/\bcuadro clinico\b/,
    ~r/\bdsm-?\s?(iv|v|5)\b/,
    ~r/\bcie-?\s?1[01]\b/
  ]

  @prescriptive_patterns [
    # recomiendo, recomendación, recomendamos
    ~r/\brecom(iend|end)\w*\b/,
    ~r/\btratamiento\b/,
    ~r/\biniciar terapia\b/,
    # prescribir, prescripción
    ~r/\bprescri\w*\b/,
    ~r/\bmedica(r|cion|mento)\w*\b/,
    ~r/\bderivar\s+(a|al)\b/,
    ~r/\bdeberia\w*\s+(iniciar|comenzar|empezar|tomar|suspender|derivar|indicar)\b/,
    ~r/\bhay que\s+(iniciar|indicar|derivar|medicar)\b/,
    ~r/\bse sugiere\s+(iniciar|indicar|tratamiento)\b/
  ]

  @doc """
  The 9 diagnostic-language regexes, in fixed documented order.
  """
  @spec diagnostic_patterns() :: [Regex.t()]
  def diagnostic_patterns, do: @diagnostic_patterns

  @doc """
  The 9 prescriptive-language regexes, in fixed documented order.
  """
  @spec prescriptive_patterns() :: [Regex.t()]
  def prescriptive_patterns, do: @prescriptive_patterns

  @doc """
  Shared normalization for both pattern lists: downcase, accent-fold
  (keeps ñ), collapse whitespace.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.downcase()
    |> fold_accents()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @accent_map %{
    "á" => "a",
    "é" => "e",
    "í" => "i",
    "ó" => "o",
    "ú" => "u",
    "ü" => "u"
  }

  defp fold_accents(text) do
    Enum.reduce(@accent_map, text, fn {accented, plain}, acc ->
      String.replace(acc, accented, plain)
    end)
  end
end
