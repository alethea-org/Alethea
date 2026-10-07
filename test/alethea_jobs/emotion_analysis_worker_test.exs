defmodule AletheaJobs.EmotionAnalysisWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import ExUnit.CaptureLog

  alias Alethea.{Accounts, Clinical, Repo}
  alias AletheaJobs.EmotionAnalysisWorker
  alias Alethea.Clinical.{EmotionAnalysis, Trend}

  # Issue #198 — the :emotion_analyzer slot is wired to
  # Alethea.AI.EmotionAnalyzer.Fake in config/test.exs by default.
  # The Fake returns a fixed canonical vector (joy=0.8 dominant) — the
  # happy-path tests below rely on that shape. The
  # "unavailable / malformed" branch swaps in the inline Mox mock
  # because those failure shapes must NOT depend on the Fake's vector.
  setup :set_mox_from_context
  setup :verify_on_exit!

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

      %{message: message, patient: patient, professional: professional}
    end

    test "canonical success inserts analysis and derived trends", %{message: message} do
      assert {:ok, analysis} =
               EmotionAnalysisWorker.perform(%Oban.Job{args: %{"message_id" => message.id}})

      # Alethea.AI.EmotionAnalyzer.Fake returns a fixed canonical vector
      # with joy=0.8 dominant. Assert the worker honors it.
      assert analysis.dominant_label == "joy"
      assert analysis.joy_score == 0.8
      assert analysis.sadness_score == 0.05
      assert analysis.anger_score == 0.05
      assert analysis.fear_score == 0.05
      assert analysis.neutral_score == 0.05
      assert Repo.aggregate(Trend, :count) > 0
      assert analysis.message_id in Repo.all(from a in EmotionAnalysis, select: a.message_id)
    end

    test "notifies the owning professional after persisting analysis and trends", %{
      message: message,
      patient: patient,
      professional: professional
    } do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "patients:#{professional.id}")

      assert {:ok, _analysis} =
               EmotionAnalysisWorker.perform(%Oban.Job{args: %{"message_id" => message.id}})

      patient_id = patient.id
      assert_receive {:emotion_trends_updated, ^patient_id}
    end

    test "unavailable or malformed analysis inserts neither analysis nor trends", %{
      message: message
    } do
      # The Fake always returns the canonical vector — to exercise the
      # error path we swap in an inline Mox mock that returns each
      # failure shape and restore the Fake on exit. This mirrors the
      # issue #198 acceptance criterion: replacement consumer behavior
      # and failure handling are exercised deterministically.
      original = Application.get_env(:alethea, :emotion_analyzer)
      Application.put_env(:alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzerBehaviourMock)

      on_exit(fn ->
        if original do
          Application.put_env(:alethea, :emotion_analyzer, original)
        else
          Application.delete_env(:alethea, :emotion_analyzer)
        end
      end)

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
        expect(Alethea.AI.EmotionAnalyzerBehaviourMock, :analyze_batch, fn _texts -> result end)

        capture_log(fn ->
          assert {:error, _} =
                   EmotionAnalysisWorker.perform(%Oban.Job{args: %{"message_id" => message.id}})
        end)

        assert Repo.aggregate(EmotionAnalysis, :count) == 0
        assert Repo.aggregate(Trend, :count) == 0
      end
    end

    # Issue #402 — a switched-off analyzer is a configured state, not a
    # failure: the job that every inbound message enqueues must finish
    # quietly and leave nothing behind.
    test "a disabled analyzer completes without analysis, trends or log noise", %{
      message: message,
      professional: professional
    } do
      with_analyzer(Alethea.AI.EmotionAnalyzer.Disabled)
      Phoenix.PubSub.subscribe(Alethea.PubSub, "patients:#{professional.id}")

      log =
        capture_log(fn ->
          assert :ok = perform_job(EmotionAnalysisWorker, %{message_id: message.id})
        end)

      assert Repo.aggregate(EmotionAnalysis, :count) == 0
      assert Repo.aggregate(Trend, :count) == 0
      refute_receive {:emotion_trends_updated, _patient_id}
      refute log =~ "EmotionAnalysisWorker"
    end

    test "an unconfigured analyzer slot completes instead of raising", %{message: message} do
      with_analyzer(nil)

      assert :ok = perform_job(EmotionAnalysisWorker, %{message_id: message.id})
      assert Repo.aggregate(EmotionAnalysis, :count) == 0
    end
  end

  # Sentiment regression (repo CLAUDE.md mandate: "Every AI pipeline change
  # must include a sentiment regression test"). Issue #402 added the
  # disabled state in front of the analyzer; these tests pin that the
  # enabled path still turns the same sidecar response into the same
  # persisted sentiment, through the real `Alethea.AI.EmotionAnalyzer`
  # parsing code (`Req.Test` stands in for the sidecar). Expected values
  # are literals taken from the stubbed response, not recomputed.
  describe "sentiment regression — enabled analyzer (issue #402)" do
    setup do
      {:ok, professional} =
        Accounts.create_professional(%{
          email: "sentiment_regression_#{System.unique_integer([:positive])}@example.com",
          password: "securepassword123",
          full_name: "Sentiment Regression Tester"
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

      previous_config = Application.get_env(:alethea, Alethea.AI.EmotionAnalyzer)
      with_analyzer(Alethea.AI.EmotionAnalyzer)

      Application.put_env(:alethea, Alethea.AI.EmotionAnalyzer,
        base_url: "http://emotion-sidecar.test",
        connect_timeout: 100,
        receive_timeout: 100,
        max_batch_size: 32,
        max_text_bytes: 4096,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

      on_exit(fn ->
        Application.put_env(:alethea, Alethea.AI.EmotionAnalyzer, previous_config)
      end)

      %{message: message, patient: patient}
    end

    test "a sadness-dominant response persists the same scores, label and anchor", %{
      message: message,
      patient: patient
    } do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "version" => "v1",
          "results" => [
            %{
              "label" => "sadness",
              "scores" => %{
                "others" => 0.05,
                "joy" => 0.025,
                "sadness" => 0.75,
                "anger" => 0.05,
                "surprise" => 0.0,
                "disgust" => 0.0,
                "fear" => 0.125
              }
            }
          ]
        })
      end)

      assert Alethea.AI.enabled?(:emotion_analyzer)

      assert {:ok, analysis} = perform_job(EmotionAnalysisWorker, %{message_id: message.id})

      assert analysis.dominant_label == "sadness"
      assert analysis.confidence == 0.75
      assert analysis.joy_score == 0.025
      assert analysis.sadness_score == 0.75
      assert analysis.anger_score == 0.05
      assert analysis.fear_score == 0.125
      assert analysis.neutral_score == 0.05
      # Source anchoring: the analysis points at the originating message.
      assert analysis.message_id == message.id

      trends =
        Repo.all(from t in Trend, where: t.patient_id == ^patient.id)
        |> Map.new(&{&1.indicator_name, &1.score})

      assert trends == %{
               "joy" => 0.025,
               "sadness" => 0.75,
               "anger" => 0.05,
               "fear" => 0.125,
               "neutral" => 0.05
             }

      # The behaviour tag of the analysed message is untouched.
      assert Repo.get!(Alethea.Clinical.Message, message.id).behavior_type == "spontaneous"
    end

    test "the deterministic adapter still yields its pinned joy-dominant vector", %{
      message: message
    } do
      with_analyzer(Alethea.AI.EmotionAnalyzer.Fake)

      assert {:ok, analysis} = perform_job(EmotionAnalysisWorker, %{message_id: message.id})

      assert {analysis.dominant_label, analysis.confidence} == {"joy", 0.8}

      assert {analysis.joy_score, analysis.sadness_score, analysis.anger_score,
              analysis.fear_score, analysis.neutral_score} == {0.8, 0.05, 0.05, 0.05, 0.05}
    end
  end

  defp with_analyzer(adapter) do
    original = Application.fetch_env(:alethea, :emotion_analyzer)

    if adapter,
      do: Application.put_env(:alethea, :emotion_analyzer, adapter),
      else: Application.delete_env(:alethea, :emotion_analyzer)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:alethea, :emotion_analyzer, value)
        :error -> Application.delete_env(:alethea, :emotion_analyzer)
      end
    end)
  end
end
