defmodule AletheaJobs.EmotionAnalysisWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import ExUnit.CaptureLog

  alias Alethea.{Accounts, Clinical, Repo}
  alias AletheaJobs.EmotionAnalysisWorker
  alias Alethea.Clinical.{EmotionAnalysis, Trend}

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous_analyzer = Application.get_env(:alethea, :emotion_analyzer)
    Application.put_env(:alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzerMock)

    on_exit(fn ->
      if previous_analyzer do
        Application.put_env(:alethea, :emotion_analyzer, previous_analyzer)
      else
        Application.delete_env(:alethea, :emotion_analyzer)
      end
    end)
  end

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

    test "rejects incomplete and all-zero score vectors" do
      assert EmotionAnalysisWorker.emotion_data([%{label: "joy", score: 0.8}]) == nil

      assert EmotionAnalysisWorker.emotion_data([
               %{label: "joy", score: 0.0},
               %{label: "sadness", score: 0.0},
               %{label: "anger", score: 0.0},
               %{label: "fear", score: 0.0},
               %{label: "neutral", score: 0.0}
             ]) == nil
    end
  end

  describe "emotion persistence" do
    setup do
      {:ok, professional} =
        Accounts.create_professional(%{
          email: "emotion_worker_#{System.unique_integer([:positive])}@example.com",
          password: "securepassword123",
          full_name: "Emotion Worker Tester"
        })

      {:ok, kek} = Accounts.load_professional_kek(professional)

      {:ok, patient} =
        Accounts.create_patient(
          %{"alias" => "Synthetic Patient", "professional_id" => professional.id},
          kek
        )

      {:ok, _patient} = Accounts.update_patient_terms(patient, true)
      patient = Accounts.get_patient!(patient.id)
      {:ok, session} = Alethea.Clinical.SessionManager.open_session(patient)

      {:ok, message} =
        Clinical.save_message(
          patient,
          "Synthetic fixed message",
          nil,
          "inbound",
          "spontaneous",
          session.id
        )

      %{message: message}
    end

    test "canonical success inserts analysis and derived trends", %{message: message} do
      expect(Alethea.AI.EmotionAnalyzerMock, :analyze_batch, fn _texts ->
        {:ok,
         [
           %{label: "joy", score: 0.8},
           %{label: "sadness", score: 0.05},
           %{label: "anger", score: 0.05},
           %{label: "fear", score: 0.05},
           %{label: "neutral", score: 0.05}
         ]}
      end)

      assert {:ok, analysis} =
               EmotionAnalysisWorker.perform(%Oban.Job{args: %{"message_id" => message.id}})

      assert analysis.dominant_label == "joy"
      assert analysis.joy_score == 0.8
      assert Repo.aggregate(Trend, :count) > 0
      assert analysis.message_id in Repo.all(from a in EmotionAnalysis, select: a.message_id)
    end

    test "unavailable or malformed analysis inserts neither analysis nor trends", %{
      message: message
    } do
      for result <- [
            {:error, :unavailable},
            {:ok, [%{label: "joy", score: 0.8}]},
            {:ok,
             [
               %{label: "joy", score: 0.0},
               %{label: "sadness", score: 0.0},
               %{label: "anger", score: 0.0},
               %{label: "fear", score: 0.0},
               %{label: "neutral", score: 0.0}
             ]}
          ] do
        expect(Alethea.AI.EmotionAnalyzerMock, :analyze_batch, fn _texts -> result end)

        capture_log(fn ->
          assert {:error, _} =
                   EmotionAnalysisWorker.perform(%Oban.Job{args: %{"message_id" => message.id}})
        end)

        assert Repo.aggregate(EmotionAnalysis, :count) == 0
        assert Repo.aggregate(Trend, :count) == 0
      end
    end
  end
end
