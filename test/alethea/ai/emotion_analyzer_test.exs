defmodule Alethea.AI.EmotionAnalyzerTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.EmotionAnalyzer

  setup do
    original_config = Application.get_env(:alethea, EmotionAnalyzer)

    Application.put_env(:alethea, EmotionAnalyzer,
      base_url: "http://emotion-sidecar.test",
      connect_timeout: 100,
      receive_timeout: 100,
      max_batch_size: 32,
      max_text_bytes: 4096,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:alethea, EmotionAnalyzer, original_config) end)
    :ok
  end

  test "analyze_batch/1 returns averaged canonical scores" do
    expect_results([
      result("joy", %{"joy" => 0.7, "surprise" => 0.2, "others" => 0.1}),
      result("others", %{"others" => 0.7, "sadness" => 0.2, "disgust" => 0.1})
    ])

    assert {:ok, scores} = EmotionAnalyzer.analyze_batch(["Synthetic one", "Synthetic two"])
    assert score(scores, "joy") == 0.35
    assert score(scores, "sadness") == 0.1
    assert_in_delta score(scores, "neutral"), 0.4, 0.0001
  end

  test "analyze_batch/1 maps official others to neutral" do
    expect_results([result("others", %{"others" => 0.8, "joy" => 0.2})])

    assert {:ok, scores} = EmotionAnalyzer.analyze_batch(["Synthetic neutral"])
    assert score(scores, "neutral") == 0.8
  end

  test "analyze_batch/1 rejects unknown dominant labels" do
    expect_results([result("unknown", %{"unknown" => 0.9, "joy" => 0.1})])
    assert EmotionAnalyzer.analyze_batch(["Synthetic"]) == {:error, :unavailable}
  end

  # Issue #334 — surprise/disgust are valid provider labels (both are in
  # @official_labels) with no canonical counterpart. Option A: project
  # onto the 5 canonical labels by keeping their scores AS-IS and
  # dropping the surprise/disgust mass — NO renormalization to sum 1,
  # NO reassignment of the dropped mass to other labels.
  test "analyze_batch/1 keeps canonical scores unchanged (no renormalization) when the dominant label is surprise" do
    expect_results([
      result("surprise", %{
        "surprise" => 0.6,
        "joy" => 0.1,
        "sadness" => 0.1,
        "anger" => 0.05,
        "fear" => 0.05,
        "others" => 0.1
      })
    ])

    assert {:ok, scores} = EmotionAnalyzer.analyze_batch(["Synthetic surprise"])
    assert score(scores, "joy") == 0.1
    assert score(scores, "sadness") == 0.1
    assert score(scores, "anger") == 0.05
    assert score(scores, "fear") == 0.05
    assert score(scores, "neutral") == 0.1
  end

  test "analyze_batch/1 keeps canonical scores unchanged (no renormalization) when the dominant label is disgust" do
    expect_results([
      result("disgust", %{
        "disgust" => 0.7,
        "joy" => 0.05,
        "sadness" => 0.1,
        "anger" => 0.05,
        "fear" => 0.05,
        "others" => 0.05
      })
    ])

    assert {:ok, scores} = EmotionAnalyzer.analyze_batch(["Synthetic disgust"])
    assert score(scores, "joy") == 0.05
    assert score(scores, "sadness") == 0.1
    assert score(scores, "anger") == 0.05
    assert score(scores, "fear") == 0.05
    assert score(scores, "neutral") == 0.05
  end

  test "analyze_batch/1 averages a surprise-dominant result into a mixed batch without renormalizing it first" do
    expect_results([
      result("joy", %{"joy" => 0.9, "sadness" => 0.05, "others" => 0.05}),
      result("surprise", %{"surprise" => 0.7, "fear" => 0.2, "others" => 0.1})
    ])

    assert {:ok, scores} =
             EmotionAnalyzer.analyze_batch(["Synthetic joy", "Synthetic surprise"])

    assert score(scores, "joy") == 0.45
    assert score(scores, "sadness") == 0.025
    assert score(scores, "anger") == 0.0
    assert score(scores, "fear") == 0.1
    assert_in_delta score(scores, "neutral"), 0.075, 0.0001
  end

  test "analyze_batch/1 fails closed on transport and HTTP errors" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert EmotionAnalyzer.analyze_batch(["Synthetic"]) == {:error, :unavailable}

    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert EmotionAnalyzer.analyze_batch(["Synthetic"]) == {:error, :unavailable}
  end

  test "analyze_batch/1 fails closed on invalid JSON, cardinality, and zero vectors" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "not-json")
    end)

    assert EmotionAnalyzer.analyze_batch(["Synthetic"]) == {:error, :unavailable}

    expect_results([])
    assert EmotionAnalyzer.analyze_batch(["Synthetic"]) == {:error, :unavailable}

    expect_results([result("joy", Map.new(official_labels(), &{&1, 0.0}))])
    assert EmotionAnalyzer.analyze_batch(["Synthetic"]) == {:error, :unavailable}
  end

  defp expect_results(results) do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"version" => "v1", "results" => results})
    end)
  end

  defp result(label, overrides) do
    scores = Map.merge(Map.new(official_labels(), &{&1, 0.0}), overrides)
    %{"label" => label, "scores" => scores}
  end

  defp official_labels, do: ~w(others joy sadness anger surprise disgust fear)
  defp score(scores, label), do: Enum.find(scores, &(&1.label == label)).score
end
