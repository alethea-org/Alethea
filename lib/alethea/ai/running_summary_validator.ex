defmodule Alethea.AI.RunningSummaryValidator do
  @moduledoc """
  Decides whether a generated running summary (#394) may be stored or
  attached to a reply.

  A summary is valid when it:

  - is at most 1200 characters once trimmed;
  - follows a strict line grammar: the heading `Hechos que la persona
    relató:`, then `- ` bullets or blank lines, then the heading
    `Preguntas que Alethea hizo:`, then `- ` bullets or blank lines.
    Any other line (missing, extra, duplicated or reordered headings,
    free text) is rejected;
  - passes `Alethea.AI.JournalingOutputGuard.check/1`;
  - does not reproduce the resolved crisis copy, either whole or as any
    single copy line of at least 20 normalized characters. Empty
    lines and shorter lines (a short whole copy included) are ignored to avoid false positives on
    short generic phrases. A blank copy is skipped.
  """

  alias Alethea.AI.ClinicalSafetyPatterns
  alias Alethea.AI.JournalingOutputGuard

  @max_length 1200
  @min_crisis_line_length 20
  @facts_heading "Hechos que la persona relató:"
  @questions_heading "Preguntas que Alethea hizo:"

  @doc """
  Validates `text` against the format rules and the resolved
  `crisis_copy` (the text returned by `Alethea.Alerts.CrisisCopy.reply_text/1`).
  """
  @spec validate(term(), String.t() | nil) :: :ok | {:error, :invalid_summary}
  def validate(text, crisis_copy) when is_binary(text) do
    trimmed = String.trim(text)

    with true <- String.length(trimmed) <= @max_length,
         true <- well_formed?(trimmed),
         :ok <- JournalingOutputGuard.check(trimmed),
         false <- copies_crisis_text?(trimmed, crisis_copy) do
      :ok
    else
      _ -> {:error, :invalid_summary}
    end
  end

  def validate(_text, _crisis_copy), do: {:error, :invalid_summary}

  defp well_formed?(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> grammar?(:start)
  end

  defp grammar?([@facts_heading | rest], :start), do: grammar?(rest, :facts)
  defp grammar?([@questions_heading | rest], :facts), do: grammar?(rest, :questions)

  defp grammar?(["- " <> _ | rest], section) when section in [:facts, :questions],
    do: grammar?(rest, section)

  defp grammar?([], :questions), do: true
  defp grammar?(_lines, _state), do: false

  defp copies_crisis_text?(_text, copy) when not is_binary(copy), do: false

  defp copies_crisis_text?(text, copy) do
    haystack = ClinicalSafetyPatterns.normalize(text)

    [copy | String.split(copy, ~r/\R/)]
    |> Enum.map(&ClinicalSafetyPatterns.normalize/1)
    |> Enum.filter(&(String.length(&1) >= @min_crisis_line_length))
    |> Enum.any?(&String.contains?(haystack, &1))
  end
end
