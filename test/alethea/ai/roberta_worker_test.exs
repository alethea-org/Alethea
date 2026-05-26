defmodule Alethea.AI.RoBERTaWorkerTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.RoBERTaWorker

  @hf_response [
    [
      %{"label" => "joy", "score" => 0.70},
      %{"label" => "sadness", "score" => 0.10},
      %{"label" => "anger", "score" => 0.05},
      %{"label" => "fear", "score" => 0.05},
      %{"label" => "neutral", "score" => 0.10}
    ],
    [
      %{"label" => "joy", "score" => 0.30},
      %{"label" => "sadness", "score" => 0.50},
      %{"label" => "anger", "score" => 0.05},
      %{"label" => "fear", "score" => 0.05},
      %{"label" => "neutral", "score" => 0.10}
    ]
  ]

  setup do
    Req.Test.stub(Alethea.AI.RoBERTaWorker, fn conn ->
      Req.Test.json(conn, @hf_response)
    end)

    :ok
  end

  test "analyze_batch/1 returns averaged canonical emotions for a batch of texts" do
    result = RoBERTaWorker.analyze_batch(["Me siento bien hoy", "Estoy triste"])

    assert length(result) == 5
    labels = Enum.map(result, & &1.label)
    assert Enum.sort(labels) == Enum.sort(~w(joy sadness anger fear neutral))

    joy = Enum.find(result, &(&1.label == "joy"))
    assert_in_delta joy.score, 0.50, 0.01

    sadness = Enum.find(result, &(&1.label == "sadness"))
    assert_in_delta sadness.score, 0.30, 0.01
  end

  test "analyze_batch/1 returns zero scores for empty input" do
    result = RoBERTaWorker.analyze_batch([])
    assert length(result) == 5
    assert Enum.all?(result, fn %{score: s} -> s == 0.0 end)
  end

  test "analyze_batch/1 normalizes spanish and alternative labels to canonical keys" do
    Req.Test.stub(Alethea.AI.RoBERTaWorker, fn conn ->
      Req.Test.json(conn, [
        [
          %{"label" => "alegría", "score" => 0.80},
          %{"label" => "others", "score" => 0.20}
        ]
      ])
    end)

    result = RoBERTaWorker.analyze_batch(["Qué alegría!"])
    joy = Enum.find(result, &(&1.label == "joy"))
    neutral = Enum.find(result, &(&1.label == "neutral"))

    assert joy.score == 0.80
    assert neutral.score == 0.20
  end
end
