defmodule Alethea.AI.TriggerMatcher.Fake do
  @moduledoc """
  Deterministic reactive-trigger matcher for the `:test` and `:dev`
  environments (#448).

  Implements `Alethea.AI.TriggerMatcherBehaviour` with zero network. The
  probability for a candidate is the share of its condition's significant
  words (four or more letters, case-insensitive) that also appear as words
  in the burst text: `1.0` when every one appears, `0.0` when none does or
  the condition has no significant word.

  It makes no claim of clinical or semantic validity; it only gives tests
  and local development a stable, explainable shape. Production never
  selects it (`config/runtime.exs` refuses to boot with the matcher
  enabled until a real adapter exists, #449).
  """

  @behaviour Alethea.AI.TriggerMatcherBehaviour

  @min_word_length 4

  @impl true
  def match(text, candidates) when is_binary(text) and is_list(candidates) do
    text_words = MapSet.new(words(text))

    probabilities =
      Map.new(candidates, fn %{id: id, condition: condition} ->
        {id, overlap(words(condition), text_words)}
      end)

    {:ok, probabilities}
  end

  def match(_text, _candidates), do: {:error, :invalid_input}

  defp overlap(condition_words, text_words) do
    significant =
      condition_words
      |> Enum.filter(&(String.length(&1) >= @min_word_length))
      |> Enum.uniq()

    case significant do
      [] -> 0.0
      _ -> Enum.count(significant, &MapSet.member?(text_words, &1)) / length(significant)
    end
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}]+/u, trim: true)
  end
end
