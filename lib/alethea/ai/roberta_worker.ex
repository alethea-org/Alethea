defmodule Alethea.AI.RoBERTaWorker do
  @behaviour Alethea.AI.RoBERTaWorkerBehavior

  @canonical_labels ~w(joy sadness anger fear neutral)

  @label_map %{
    "joy" => "joy",
    "alegría" => "joy",
    "alegria" => "joy",
    "sadness" => "sadness",
    "tristeza" => "sadness",
    "anger" => "anger",
    "ira" => "anger",
    "fear" => "fear",
    "miedo" => "miedo",
    "neutral" => "neutral",
    "others" => "neutral"
  }

  @impl true
  def analyze_batch([]), do: empty_result()

  def analyze_batch(texts) when is_list(texts) do
    config = Application.get_env(:alethea, __MODULE__, [])
    api_url = Keyword.fetch!(config, :api_url)
    api_key = Keyword.fetch!(config, :api_key)
    req_opts = Keyword.get(config, :req_options, [])

    base_opts = [
      json: %{inputs: texts},
      headers: [{"Authorization", "Bearer #{api_key}"}]
    ]

    response = Req.post!(api_url, base_opts ++ req_opts)

    response.body
    |> normalize_batch()
    |> average_scores(length(texts))
  end

  defp normalize_batch(results) when is_list(results) do
    Enum.map(results, fn message_emotions ->
      Enum.reduce(message_emotions, %{}, fn %{"label" => label, "score" => score}, acc ->
        case Map.get(@label_map, String.downcase(label)) do
          nil -> acc
          canonical -> Map.update(acc, canonical, score, &(&1 + score))
        end
      end)
    end)
  end

  defp average_scores(normalized_list, count) do
    base = Map.new(@canonical_labels, fn l -> {l, 0.0} end)

    totals =
      Enum.reduce(normalized_list, base, fn emotions, acc ->
        Enum.reduce(emotions, acc, fn {label, score}, inner_acc ->
          Map.update(inner_acc, label, score, &(&1 + score))
        end)
      end)

    Enum.map(@canonical_labels, fn label ->
      %{label: label, score: totals[label] / count}
    end)
  end

  defp empty_result do
    Enum.map(@canonical_labels, fn label -> %{label: label, score: 0.0} end)
  end
end
