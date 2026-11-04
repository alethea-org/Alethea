defmodule Alethea.Jobs.TelegramMessageWorkerReactiveTriggersTest do
  @moduledoc """
  Reactive triggers (#448) are matched only on the `:safe` path, inside the
  burst reply. The crisis and uncertainty paths never call the trigger
  matcher — not even through a burst job that runs after a crisis.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox
  import Ecto.Query
  import Alethea.FoundationTestHelper

  alias Alethea.AI.{PhiWorkerMock, TriggerMatcherMock}
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.{TelegramBurstReplyWorker, TelegramMessageWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}
  alias AletheaJobs.EmotionAnalysisWorker

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @crisis_text "me voy a quitar la vida"

  setup :verify_on_exit!

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    original = Application.fetch_env!(:alethea, :trigger_matcher)
    Application.put_env(:alethea, :trigger_matcher, TriggerMatcherMock)
    on_exit(fn -> Application.put_env(:alethea, :trigger_matcher, original) end)

    stub(PhiWorkerMock, :process, fn %{message_id: mid} ->
      {:ok,
       %{
         response: "respuesta clínica",
         source_message_id: mid,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}
    end)

    %{legacy_pro: professional, legacy_pat: patient} = bind_patient()

    {:ok, trigger} =
      Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
        "condition" => "Pelea con mamá",
        "instruction" => "Retomar la comunicación asertiva",
        "approved_text" => "¿Pudiste hablar con calma?"
      })

    %{trigger: trigger}
  end

  test "the crisis path never calls the matcher, even when a burst job runs afterwards",
       %{trigger: trigger} do
    expect(TriggerMatcherMock, :match, 0, fn _, _ -> flunk("crisis must not match triggers") end)

    assert :ok = perform_inbound("pelea con mi mamá", 501)
    assert :ok = perform_inbound(@crisis_text, 502)

    for job <- all_enqueued(worker: TelegramBurstReplyWorker) do
      assert :ok = perform_job(TelegramBurstReplyWorker, job.args)
    end

    assert Repo.get!(Trigger, trigger.id).status == "paused_by_crisis"
    assert Repo.aggregate(TriggerFiring, :count) == 0
  end

  test "the uncertainty path never calls the matcher" do
    Application.put_env(:alethea, :telegram_additional_risk_signal, fn ->
      {:available, :uncertain}
    end)

    on_exit(fn -> Application.delete_env(:alethea, :telegram_additional_risk_signal) end)

    expect(TriggerMatcherMock, :match, 0, fn _, _ ->
      flunk("uncertainty must not match triggers")
    end)

    expect(PhiWorkerMock, :process, 0, fn _ -> flunk("uncertainty must not generate") end)

    assert :ok = perform_inbound("pelea con mi mamá", 511)

    refute_enqueued(worker: TelegramBurstReplyWorker)
    assert Repo.aggregate(TriggerFiring, :count) == 0
  end

  test "the safe path calls the matcher exactly once per burst" do
    expect(TriggerMatcherMock, :match, 1, fn _text, [_candidate] -> {:ok, %{}} end)

    assert :ok = perform_inbound("pelea con mi mamá", 521)
    assert :ok = perform_inbound("y luego lloré", 522)

    assert [job] = all_enqueued(worker: TelegramBurstReplyWorker)
    assert :ok = perform_job(TelegramBurstReplyWorker, job.args)
  end

  test "sentiment regression: a matched burst feeds emotion analysis and the model " <>
         "exactly like an unmatched one",
       %{trigger: trigger} do
    test_pid = self()

    stub(PhiWorkerMock, :process, fn %{message_id: mid} = request ->
      send(test_pid, {:request, request})

      {:ok,
       %{
         response: "respuesta clínica",
         source_message_id: mid,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}
    end)

    # Burst 1: the matcher scores the trigger below the threshold.
    expect(TriggerMatcherMock, :match, fn _text, [_] -> {:ok, %{trigger.id => 0.1}} end)
    assert :ok = perform_inbound("hoy fue un día pesado", 531)
    unmatched = inbound!(531)
    assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: unmatched.id})
    run_burst!()
    assert_receive {:request, unmatched_request}
    refute Map.has_key?(unmatched_request, :trigger)

    # Burst 2: the matcher scores the trigger above the threshold.
    expect(TriggerMatcherMock, :match, fn _text, [_] -> {:ok, %{trigger.id => 0.95}} end)
    assert :ok = perform_inbound("pelea con mi mamá", 532)
    matched = inbound!(532)
    assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: matched.id})
    run_burst!()
    assert_receive {:request, matched_request}
    assert matched_request.trigger == "¿Pudiste hablar con calma?"

    # The trigger is the only difference in what reaches the model: the
    # sentiment anchor (message_id) and every other key are unchanged.
    assert unmatched_request.message_id == unmatched.id
    assert matched_request.message_id == matched.id

    assert matched_request |> Map.delete(:trigger) |> Map.keys() |> Enum.sort() ==
             unmatched_request |> Map.keys() |> Enum.sort()

    for message <- [unmatched, matched] do
      diagnosis =
        Repo.one!(from d in Alethea.AI.Diagnosis, where: d.message_id == ^message.id)

      assert diagnosis.model_version == "phi-4-mini"
      assert Repo.get!(Message, message.id).behavior_type == "spontaneous"
    end

    assert [%TriggerFiring{message_id: firing_message_id}] = Repo.all(TriggerFiring)
    assert firing_message_id == matched.id
  end

  defp inbound!(telegram_message_id) do
    Repo.one!(
      from m in Message,
        where:
          m.direction == "inbound" and
            fragment("?::bigint", m.telegram_message_id) == ^telegram_message_id
    )
  end

  defp run_burst! do
    assert [job] = all_enqueued(worker: TelegramBurstReplyWorker)
    assert :ok = perform_job(TelegramBurstReplyWorker, job.args)
  end

  defp perform_inbound(text, id) do
    TelegramMessageWorker.perform(%Oban.Job{
      args: %{
        "telegram_update_id" => id,
        "message" => %{
          "message_id" => id,
          "date" => 1_700_000_000,
          "chat" => %{"id" => @chat_id, "type" => "private"},
          "text" => text
        }
      }
    })
  end

  defp bind_patient do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    legacy_pro =
      legacy_pro
      |> Ecto.Changeset.change(%{crisis_message: "Texto de crisis de prueba"})
      |> Repo.update!()

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_pro)

    {:ok, legacy_pat} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_pro.id},
        kek
      )

    foundation_pat
    |> Ecto.Changeset.change(%{
      telegram_chat_id_hash: @chat_id_hash,
      legacy_patient_id: legacy_pat.id
    })
    |> Repo.update!()

    %{legacy_pro: legacy_pro, legacy_pat: legacy_pat}
  end

  defp unique_int, do: System.unique_integer([:positive])
end
