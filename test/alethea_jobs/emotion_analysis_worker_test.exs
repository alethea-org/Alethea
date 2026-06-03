defmodule AletheaJobs.EmotionAnalysisWorkerTest do
  use ExUnit.Case, async: true

  alias AletheaJobs.EmotionAnalysisWorker
  alias Alethea.Clinical.EmotionAnalysis

  describe "EmotionAnalysis schema" do
    test "computes dominant label correctly" do
      analysis = %EmotionAnalysis{
        joy_score: 0.1,
        sadness_score: 0.8,
        anger_score: 0.05,
        fear_score: 0.02,
        neutral_score: 0.03
      }

      result = EmotionAnalysis.compute_dominant(analysis)

      assert result.label == :sadness
      assert result.confidence == 0.8
    end

    test "handles tie in scores" do
      analysis = %EmotionAnalysis{
        joy_score: 0.5,
        sadness_score: 0.5,
        anger_score: 0.0,
        fear_score: 0.0,
        neutral_score: 0.0
      }

      result = EmotionAnalysis.compute_dominant(analysis)

      # Enum.max_by no garantiza orden en empates, solo verificamos que sea uno de los empatados
      assert result.label in [:joy, :sadness]
    end

    test "formats context string correctly" do
      analysis = %EmotionAnalysis{
        joy_score: 0.3,
        sadness_score: 0.6,
        anger_score: 0.05,
        fear_score: 0.02,
        neutral_score: 0.03,
        dominant_label: "sadness",
        confidence: 0.6
      }

      context = EmotionAnalysis.to_context_string(analysis)

      assert context =~ "joy: 0.300"
      assert context =~ "sadness: 0.600"
      assert context =~ "anger: 0.050"
      assert context =~ "fear: 0.020"
      assert context =~ "neutral: 0.030"
    end

    test "formats nil scores as N/A" do
      analysis = %EmotionAnalysis{
        joy_score: nil,
        sadness_score: nil,
        anger_score: nil,
        fear_score: nil,
        neutral_score: nil
      }

      context = EmotionAnalysis.to_context_string(analysis)

      assert context =~ "N/A"
    end
  end
end
