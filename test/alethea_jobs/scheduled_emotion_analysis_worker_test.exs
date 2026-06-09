defmodule AletheaJobs.ScheduledEmotionAnalysisWorkerTest do
  use Alethea.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Alethea.{Accounts, Clinical, Repo}
  alias Alethea.Clinical.{EmotionAnalysis, Message, Trend}
  alias AletheaJobs.ScheduledEmotionAnalysisWorker

  setup :verify_on_exit!

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "scheduled_emotions_#{System.unique_integer([:positive])}@example.com",
        password: "securepassword123",
        full_name: "Scheduled Emotion Tester"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "whatsapp_number" => "+5411#{System.unique_integer([:positive])}",
          "alias" => "Scheduled Patient",
          "professional_id" => professional.id
        },
        kek
      )

    {:ok, _patient} = Accounts.update_patient_terms(patient, true)

    %{patient: Accounts.get_patient!(patient.id)}
  end

  test "is idempotent across consecutive runs", %{patient: patient} do
    create_message!(patient, "Me siento tranquilo")
    create_message!(patient, "Hoy tuve ansiedad")

    Alethea.AI.RoBERTaWorkerMock
    |> expect(:analyze_batch_per_message, fn texts ->
      assert length(texts) == 2
      Enum.map(texts, fn _text -> emotion_scores() end)
    end)

    assert :ok = perform_worker(%{"max_messages" => 1000, "batch_size" => 100})

    assert Repo.aggregate(EmotionAnalysis, :count) == 2
    assert Repo.aggregate(Trend, :count) == 10

    assert :ok = perform_worker(%{"max_messages" => 1000, "batch_size" => 100})

    assert Repo.aggregate(EmotionAnalysis, :count) == 2
    assert Repo.aggregate(Trend, :count) == 10
  end

  test "processes no more than max_messages", %{patient: patient} do
    create_message!(patient, "Uno")
    create_message!(patient, "Dos")
    create_message!(patient, "Tres")

    Alethea.AI.RoBERTaWorkerMock
    |> expect(:analyze_batch_per_message, fn texts ->
      assert length(texts) == 2
      Enum.map(texts, fn _text -> emotion_scores() end)
    end)

    assert :ok = perform_worker(%{"max_messages" => 2, "batch_size" => 100})

    assert Repo.aggregate(EmotionAnalysis, :count) == 2
    assert unprocessed_inbound_count() == 1
  end

  test "calls RoBERTa in configured chunks", %{patient: patient} do
    parent = self()

    Enum.each(1..5, fn index ->
      create_message!(patient, "Mensaje #{index}")
    end)

    Alethea.AI.RoBERTaWorkerMock
    |> expect(:analyze_batch_per_message, 3, fn texts ->
      send(parent, {:chunk_size, length(texts)})
      Enum.map(texts, fn _text -> emotion_scores() end)
    end)

    assert :ok = perform_worker(%{"max_messages" => 5, "batch_size" => 2})

    assert_receive {:chunk_size, 2}
    assert_receive {:chunk_size, 2}
    assert_receive {:chunk_size, 1}
    assert Repo.aggregate(EmotionAnalysis, :count) == 5
  end

  test "logs zero batch size and duration when there is no work" do
    log =
      capture_info_log(fn ->
        assert :ok = perform_worker(%{"max_messages" => 1000, "batch_size" => 100})
      end)

    assert log =~ "batch_size=0"
    assert log =~ "duration_ms="
  end

  test "logs processed batch size and duration", %{patient: patient} do
    create_message!(patient, "Necesito registrar esto")

    Alethea.AI.RoBERTaWorkerMock
    |> expect(:analyze_batch_per_message, fn texts ->
      assert length(texts) == 1
      [emotion_scores()]
    end)

    log =
      capture_info_log(fn ->
        assert :ok = perform_worker(%{"max_messages" => 1000, "batch_size" => 100})
      end)

    assert log =~ "batch_size=1"
    assert log =~ "duration_ms="
  end

  defp create_message!(patient, text, direction \\ "inbound") do
    {:ok, message} =
      Clinical.save_message(patient, text, nil, direction, "spontaneous", nil, nil)

    message
  end

  defp emotion_scores do
    [
      %{label: "joy", score: 0.7},
      %{label: "sadness", score: 0.1},
      %{label: "anger", score: 0.05},
      %{label: "fear", score: 0.05},
      %{label: "neutral", score: 0.1}
    ]
  end

  defp unprocessed_inbound_count do
    Repo.aggregate(
      from(m in Message,
        left_join: ea in assoc(m, :emotion_analysis),
        where: m.direction == "inbound" and is_nil(ea.id)
      ),
      :count
    )
  end

  defp perform_worker(args) do
    ScheduledEmotionAnalysisWorker.perform(%Oban.Job{args: args})
  end

  defp capture_info_log(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end
end
