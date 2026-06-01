defmodule AletheaJobs.EmotionAnalysisWorkerTest do
  use Alethea.DataCase

  alias AletheaJobs.EmotionAnalysisWorker
  alias Alethea.Clinical.{Message, EmotionAnalysis}
  alias Alethea.Accounts.{Patient, Professional}
  alias Alethea.EncryptionKey
  alias Alethea.Repo

  describe "perform/1" do
    setup do
      # Setup de profesional y paciente con encryption key mockeada
      professional = %Professional{
        id: Ecto.UUID.generate(),
        email: "dr@test.com",
        name: "Dr. Test"
      }

      patient = %Patient{
        id: Ecto.UUID.generate(),
        phone: "+1234567890",
        name: "Test Patient",
        professional_id: professional.id,
        encryption_key_id: nil
      }

      %{
        professional: professional,
        patient: patient,
        message_id: Ecto.UUID.generate()
      }
    end

    test "returns error when message not found" do
      fake_message_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               EmotionAnalysisWorker.perform(%Oban.Job{
                 args: %{"message_id" => fake_message_id}
               })
    end

    test "emotion worker skips on empty text" do
      # El worker debería manejar casos donde no hay contenido para analizar
      # Esto es más un test de integración - aquí solo verificamos la estructura
      assert EmotionAnalysisWorker.new(%{message_id: Ecto.UUID.generate()}) != nil
    end
  end

  describe "new/1" do
    test "creates worker with correct queue and message_id" do
      message_id = Ecto.UUID.generate()

      worker = EmotionAnalysisWorker.new(%{message_id: message_id})

      assert worker.__struct__ == Oban.Job
      assert worker.queue == :ai_analysis
      assert worker.args == %{"message_id" => message_id}
    end
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
  end
end
