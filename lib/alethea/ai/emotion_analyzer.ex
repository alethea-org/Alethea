defmodule Alethea.AI.EmotionAnalyzer do
  @moduledoc """
  Domain interface for Spanish emotion analysis.

  It hides the sidecar transport and provider labels behind five canonical
  scores. Any result that cannot be represented safely is unavailable.
  """

  @behaviour Alethea.AI.EmotionAnalyzerBehaviour

  @canonical_labels ~w(joy sadness anger fear neutral)
  @official_labels MapSet.new(~w(others joy sadness anger surprise disgust fear))
  @unrepresentable_labels ~w(surprise disgust)

  @impl true
  def analyze_batch(texts) when is_list(texts) do
    config = Application.get_env(:alethea, __MODULE__, [])

    with :ok <- validate_input(texts, config),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           request(texts, config),
         {:ok, results} <- parse_results(body, length(texts)),
         scores when is_list(scores) <- average_scores(results),
         true <- positive_score?(scores) do
      {:ok, scores}
    else
      _failure -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def analyze_batch(_texts), do: {:error, :unavailable}

  defp validate_input(texts, config) do
    max_batch_size = config[:max_batch_size] || 32
    max_text_bytes = config[:max_text_bytes] || 4096

    if length(texts) in 1..max_batch_size and
         Enum.all?(texts, &(is_binary(&1) and byte_size(&1) in 1..max_text_bytes)) do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp request(texts, config) do
    base_url = config[:base_url]

    if is_binary(base_url) and String.trim(base_url) != "" do
      Req.post(
        String.trim_trailing(base_url, "/") <> "/v1/emotions:batch",
        [
          json: %{texts: texts},
          retry: false,
          receive_timeout: config[:receive_timeout] || 30_000,
          connect_options: [timeout: config[:connect_timeout] || 2_000]
        ] ++ (config[:req_options] || [])
      )
    else
      {:error, :unavailable}
    end
  end

  defp parse_results(%{"version" => "v1", "results" => results}, expected_count)
       when is_list(results) and length(results) == expected_count do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, parsed} ->
      case parse_result(result) do
        {:ok, scores} -> {:cont, {:ok, [scores | parsed]}}
        {:error, :unavailable} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_results(_body, _expected_count), do: {:error, :unavailable}

  defp parse_result(%{"label" => dominant, "scores" => scores})
       when is_binary(dominant) and is_map(scores) do
    with true <- MapSet.equal?(MapSet.new(Map.keys(scores)), @official_labels),
         true <- dominant in @official_labels,
         false <- dominant in @unrepresentable_labels,
         true <- Enum.all?(scores, &valid_score?/1) do
      {:ok,
       %{
         "joy" => scores["joy"],
         "sadness" => scores["sadness"],
         "anger" => scores["anger"],
         "fear" => scores["fear"],
         "neutral" => scores["others"]
       }}
    else
      _failure -> {:error, :unavailable}
    end
  end

  defp parse_result(_result), do: {:error, :unavailable}

  defp valid_score?({_label, score}), do: is_number(score) and score >= 0 and score <= 1

  defp average_scores(results) do
    count = length(results)

    totals =
      Enum.reduce(results, Map.new(@canonical_labels, &{&1, 0.0}), fn result, totals ->
        Map.new(totals, fn {label, total} -> {label, total + result[label]} end)
      end)

    Enum.map(@canonical_labels, &%{label: &1, score: totals[&1] / count})
  end

  defp positive_score?(scores), do: Enum.any?(scores, &(&1.score > 0))
end
