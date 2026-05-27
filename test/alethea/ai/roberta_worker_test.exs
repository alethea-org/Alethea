defmodule Alethea.AI.RoBERTaWorkerTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.RoBERTaWorker

  @mock_response [
    %{predictions: [%{label: "joy", score: 0.70}]},
    %{predictions: [%{label: "sadness", score: 0.50}]}
  ]

  setup do
    Application.put_env(:alethea, :roberta_runner, fn _texts -> @mock_response end)

    on_exit(fn ->
      Application.delete_env(:alethea, :roberta_runner)
    end)

    :ok
  end

  test "analyze_batch/1 returns averaged canonical emotions for a batch of texts" do
    result = RoBERTaWorker.analyze_batch(["Me siento bien hoy", "Estoy triste"])

    assert length(result) == 5
    labels = Enum.map(result, & &1.label)
    assert Enum.sort(labels) == Enum.sort(~w(joy sadness anger fear neutral))

    joy = Enum.find(result, &(&1.label == "joy"))
    assert_in_delta joy.score, 0.35, 0.01

    sadness = Enum.find(result, &(&1.label == "sadness"))
    assert_in_delta sadness.score, 0.25, 0.01
  end

  test "analyze_batch/1 returns zero scores for empty input" do
    result = RoBERTaWorker.analyze_batch([])
    assert length(result) == 5
    assert Enum.all?(result, fn %{score: s} -> s == 0.0 end)
  end

  test "analyze_batch/1 normalizes spanish and alternative labels to canonical keys" do
    Application.put_env(:alethea, :roberta_runner, fn _texts ->
      [
        %{predictions: [%{label: "alegría", score: 0.80}]},
        %{predictions: [%{label: "others", score: 0.20}]}
      ]
    end)

    result = RoBERTaWorker.analyze_batch(["Qué alegría!", "Algo más"])

    joy = Enum.find(result, &(&1.label == "joy"))
    neutral = Enum.find(result, &(&1.label == "neutral"))

    # (0.8 + 0) / 2 = 0.4
    assert joy.score == 0.40
    # (0 + 0.2) / 2 = 0.1
    assert neutral.score == 0.10
  end
end
