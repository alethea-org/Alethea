defmodule Alethea.AI.EmotionAnalyzer.Fake do
  @moduledoc """
  Deterministic emotion-analyzer adapter for the `:test` and `:dev` environments.

  Implements the `Alethea.AI.EmotionAnalyzerBehaviour` contract with fixed,
  zero-network responses. `analyze_batch/1` returns a single canonical score
  vector for every input batch — the `joy` label carries a fixed confidence
  (`0.8`) and the remaining four canonical labels share the residual `0.05`
  each. The vector shape and label values are pinned so test assertions and
  trend calculations are reproducible.

  ## Why deterministic

  Tests that exercise the downstream pipeline (per-message
  `EmotionAnalysisWorker`, session-close `SessionTimeoutWorker`, trend
  aggregation, chart rendering) need a stable shape to assert against. Real
  sidecar responses would change between runs; the Fake pins both the
  dominant label and the score distribution so the persisted
  `EmotionAnalysis` rows are byte-identical across test invocations.

  ## Production swap

  The production adapter is `Alethea.AI.EmotionAnalyzer` (the HTTP sidecar
  client). The swap happens in `config :alethea, :emotion_analyzer, ...`
  — this module's surface stays stable.

  ## Development-only posture

  Per the emotion-analyzer contract (issue #198), this adapter does NOT
  claim clinical validity, benchmark performance, commercial licensing, or
  training-data provenance. It is a deterministic shape stand-in used
  strictly for development and automated tests.
  """

  @behaviour Alethea.AI.EmotionAnalyzerBehaviour

  @impl true
  def analyze_batch(texts) when is_list(texts) do
    {:ok, fixed_scores()}
  end

  def analyze_batch(_texts), do: {:error, :unavailable}

  defp fixed_scores do
    [
      %{label: "joy", score: 0.8},
      %{label: "sadness", score: 0.05},
      %{label: "anger", score: 0.05},
      %{label: "fear", score: 0.05},
      %{label: "neutral", score: 0.05}
    ]
  end
end

