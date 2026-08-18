defmodule Mix.Tasks.Alethea.Demo.ProcessTest do
  use Alethea.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import Mox

  alias Alethea.{Accounts, Clinical, Repo}
  alias Alethea.Clinical.{EmotionAnalysis, Summary}

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous_analyzer = Application.get_env(:alethea, :emotion_analyzer)
    previous_chain = Application.get_env(:alethea, :weekly_summary_chain)
    Application.put_env(:alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzerMock)
    Application.put_env(:alethea, :weekly_summary_chain, Alethea.AI.WeeklySummaryChainMock)

    on_exit(fn ->
      restore_env(:emotion_analyzer, previous_analyzer)
      restore_env(:weekly_summary_chain, previous_chain)
    end)
  end

  test "fails closed outside development" do
    assert_raise Mix.Error, "ALETHEA_DEMO_PROCESSING_FAILED reason=development_only", fn ->
      capture_io(:stderr, fn -> run_task(["--patient-id", Ecto.UUID.generate()], :test) end)
    end
  end

  test "requires exactly one valid patient identifier" do
    assert_raise Mix.Error, "usage: mix alethea.demo.process --patient-id <patient-uuid>", fn ->
      capture_io(:stderr, fn -> run_task([], :dev) end)
    end

    assert_raise Mix.Error, "ALETHEA_DEMO_PROCESSING_FAILED reason=invalid_patient_id", fn ->
      capture_io(:stderr, fn -> run_task(["--patient-id", "not-a-uuid"], :dev) end)
    end

    assert_raise Mix.Error, "ALETHEA_DEMO_PROCESSING_FAILED reason=patient_not_found", fn ->
      capture_io(:stderr, fn -> run_task(["--patient-id", Ecto.UUID.generate()], :dev) end)
    end
  end

  test "processes only the selected patient's pending entries and generates a report" do
    patient = patient_fixture("selected")
    other_patient = patient_fixture("other")
    message = inbound_message_fixture(patient, "Selected journal content")
    other_message = inbound_message_fixture(other_patient, "Other journal content")

    expect(Alethea.AI.EmotionAnalyzerMock, :analyze_batch, fn [_content] ->
      {:ok, emotion_scores()}
    end)

    expect(Alethea.AI.WeeklySummaryChainMock, :run, fn [], trends ->
      assert Enum.any?(trends, &(&1.label == "joy"))
      {:ok, weekly_report()}
    end)

    output = capture_io(fn -> run_task(["--patient-id", patient.id], :dev) end)

    assert output ==
             "ALETHEA_DEMO_PROCESSING_COMPLETE emotions_processed=1 weekly_report=generated\n"

    assert Repo.get_by(EmotionAnalysis, message_id: message.id)
    refute Repo.get_by(EmotionAnalysis, message_id: other_message.id)

    assert Repo.one(
             from summary in Summary,
               where: summary.patient_id == ^patient.id and summary.type == "weekly"
           )

    refute output =~ "Selected journal content"
    refute output =~ "Other journal content"
  end

  defp run_task(args, env) do
    Mix.Task.reenable("alethea.demo.process")
    Mix.Tasks.Alethea.Demo.Process.run(args, env)
  end

  defp patient_fixture(suffix) do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "demo_process_#{suffix}_#{System.unique_integer([:positive])}@example.com",
        password: "securepassword123",
        full_name: "Demo Process #{suffix}"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          alias: "Demo Process #{suffix}",
          professional_id: professional.id,
          terms_accepted: true
        },
        kek
      )

    patient
  end

  defp inbound_message_fixture(patient, content) do
    {:ok, message} = Clinical.save_message(patient, content, nil, "inbound", "spontaneous")
    message
  end

  defp emotion_scores do
    [
      %{label: "joy", score: 0.8},
      %{label: "sadness", score: 0.05},
      %{label: "anger", score: 0.05},
      %{label: "fear", score: 0.05},
      %{label: "neutral", score: 0.05}
    ]
  end

  defp weekly_report do
    %{
      summary_text: "Synthetic weekly report",
      status_level: "Estable",
      anxiety_score: 0.2,
      social_score: 0.7,
      emotional_range: %{"joy" => 0.8},
      crisis_events: 0,
      session_count: 0
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:alethea, key)
  defp restore_env(key, value), do: Application.put_env(:alethea, key, value)
end
