Mox.defmock(Alethea.Jobs.IdempotencyOutboundEnqueueMock, for: Alethea.Telegram.OutboundEnqueue)
Mox.defmock(Alethea.Jobs.IdempotencyTelegramClientMock, for: Alethea.Telegram.Client)

defmodule Alethea.Jobs.TelegramMessageWorkerIdempotencyTest do
  @moduledoc """
  Resume and duplicate-safety behavior of the Telegram journaling reply
  (issue #390), driven through `TelegramMessageWorker.perform/1` with the
  AI worker boundary controlled by `Alethea.AI.PhiWorkerMock` and delivery
  controlled by `Alethea.Telegram.Client.Fake`.

  One persisted patient message must complete its reply despite worker
  retries, concurrent executions, and outbound retries, without creating
  another patient-visible response.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox

  alias Alethea.AI.Diagnosis
  alias Alethea.Clinical.Message
  alias Alethea.Foundation.Accounts.OutboundDeadLetter
  alias Alethea.Jobs.{IdempotencyOutboundEnqueueMock, IdempotencyTelegramClientMock}
  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, Client.Fake, Pacer}
  alias AletheaJobs.{ClinicalRecordOutboxWorker, EmotionAnalysisWorker}

  import Alethea.FoundationTestHelper
  import Ecto.Query

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @other_chat_id 987_654_321
  @reply "respuesta clínica"
  @crisis_text "me voy a quitar la vida"
  @crisis_message "Estoy aquí para ayudarte. Llamame al 0800-..."

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    Application.put_env(
      :alethea,
      Alethea.Telegram.Pacer,
      Keyword.merge(
        Application.get_env(:alethea, Alethea.Telegram.Pacer, []),
        per_chat_capacity: 5,
        per_chat_refill_per_sec: 50.0,
        global_capacity: 30,
        global_refill_per_sec: 30.0,
        cleanup_interval_ms: 60_000,
        idle_threshold_ms: 60_000
      )
    )

    case Process.whereis(Pacer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, _} = Pacer.start_link([])

    start_supervised!(Fake)
    Fake.reset()
    Application.put_env(:alethea, :telegram_client, Fake)

    stub(Alethea.AI.PhiWorkerMock, :process, fn %{message_id: mid} -> phi_reply(mid) end)

    :ok
  end

  setup :verify_on_exit!

  describe "perform/1 — conversation-scoped inbound identity and resume" do
    test "a retry after reply generation failed resumes the persisted inbound and produces the reply" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 401, telegram_update_id: 11)
      test_pid = self()

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        send(test_pid, {:generation_for, mid})
        {:error, :service_unavailable}
      end)
      |> expect(:process, fn %{message_id: mid} ->
        send(test_pid, {:generation_for, mid})
        phi_reply(mid)
      end)

      assert_raise RuntimeError, ~r/PhiWorker error/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      assert [%Message{id: inbound_id}] = messages(patient, "inbound")
      refute_enqueued(worker: TelegramOutboundWorker)

      # The Oban retry of the same job: same args, inbound already persisted.
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert [%Message{id: ^inbound_id}] = messages(patient, "inbound")
      assert [%Message{behavior_type: "elicited"}] = messages(patient, "outbound")

      # Both attempts worked on the same persisted inbound.
      assert_received {:generation_for, ^inbound_id}
      assert_received {:generation_for, ^inbound_id}

      assert [%Oban.Job{args: %{"body" => @reply}}] =
               all_enqueued(worker: TelegramOutboundWorker)
    end

    test "resuming does not repeat the work the first execution completed for the inbound" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 402, telegram_update_id: 12)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn _ -> {:error, :service_unavailable} end)
      |> expect(:process, fn %{message_id: mid} -> phi_reply(mid) end)

      assert_raise RuntimeError, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      [inbound] = messages(patient, "inbound")
      inbound_id = inbound.id

      # One sentiment-pipeline job and one patient-voice outbox event for
      # the one inbound, not one per execution.
      assert [%Oban.Job{args: %{"message_id" => ^inbound_id}}] =
               all_enqueued(worker: EmotionAnalysisWorker)

      assert [_one_event] = all_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "equal Telegram message ids in two patients' conversations do not collide" do
      first = bind_patient(@chat_id)
      second = bind_patient(@other_chat_id)

      first_args = build_args(@chat_id, "hola", telegram_message_id: 7, telegram_update_id: 21)

      second_args =
        build_args(@other_chat_id, "buen día", telegram_message_id: 7, telegram_update_id: 22)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: first_args})
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: second_args})

      assert [%Message{telegram_message_id: "7"} = first_inbound] = messages(first, "inbound")
      assert [%Message{telegram_message_id: "7"} = second_inbound] = messages(second, "inbound")
      refute first_inbound.id == second_inbound.id

      # Each conversation gets its own reply and its own delivery job.
      assert [_] = messages(first, "outbound")
      assert [_] = messages(second, "outbound")

      chat_ids =
        [worker: TelegramOutboundWorker]
        |> all_enqueued()
        |> Enum.map(& &1.args["chat_id"])
        |> Enum.sort()

      assert chat_ids == [@chat_id, @other_chat_id]
    end
  end

  describe "perform/1 — one logical reply per inbound" do
    test "the reply records the inbound that caused it" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 500, telegram_update_id: 30)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      [inbound] = messages(patient, "inbound")
      [outbound] = messages(patient, "outbound")

      assert outbound.reply_to_message_id == inbound.id
      assert inbound.reply_to_message_id == nil
    end

    test "a repeated execution reuses the persisted reply: no second generation, diagnosis, outbound row, or delivery job" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 501, telegram_update_id: 31)
      test_pid = self()

      stub(Alethea.AI.PhiWorkerMock, :process, fn %{message_id: mid} ->
        send(test_pid, :generated)
        phi_reply(mid)
      end)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
      assert_received :generated

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
      refute_received :generated

      [inbound] = messages(patient, "inbound")
      assert [outbound] = messages(patient, "outbound")
      assert [_one_diagnosis] = diagnoses(inbound.id)

      outbound_id = outbound.id

      assert [%Oban.Job{args: %{"message_id" => ^outbound_id, "body" => @reply}}] =
               all_enqueued(worker: TelegramOutboundWorker)
    end

    test "two concurrent executions of the same job produce one reply and one delivery job" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 502, telegram_update_id: 32)
      test_pid = self()

      # Hold both executions inside reply generation until both have
      # entered it, so neither can observe the other's persisted reply
      # before generating: they must race on persistence itself.
      stub(Alethea.AI.PhiWorkerMock, :process, fn %{message_id: mid} ->
        send(test_pid, {:generating, self()})

        receive do
          :release -> phi_reply(mid)
        after
          5_000 -> {:error, :never_released}
        end
      end)

      executions =
        for _ <- 1..2 do
          Task.async(fn -> TelegramMessageWorker.perform(%Oban.Job{args: args}) end)
        end

      assert_receive {:generating, first}, 5_000
      assert_receive {:generating, second}, 5_000
      refute first == second
      send(first, :release)
      send(second, :release)

      assert [:ok, :ok] = Task.await_many(executions, 10_000)

      assert [inbound] = messages(patient, "inbound")
      assert [outbound] = messages(patient, "outbound")
      assert outbound.reply_to_message_id == inbound.id
      assert [_one_diagnosis] = diagnoses(inbound.id)

      outbound_id = outbound.id

      assert [%Oban.Job{args: %{"message_id" => ^outbound_id}}] =
               all_enqueued(worker: TelegramOutboundWorker)
    end

    test "a failure between persisting the reply and enqueueing its delivery is recovered on resume" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 503, telegram_update_id: 33)
      test_pid = self()

      stub(Alethea.AI.PhiWorkerMock, :process, fn %{message_id: mid} ->
        send(test_pid, :generated)
        phi_reply(mid)
      end)

      fail_outbound_enqueue_once()

      assert_raise RuntimeError, ~r/failed to enqueue TelegramOutboundWorker/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      # The reply is persisted but has no delivery job.
      assert_received :generated
      assert [outbound] = messages(patient, "outbound")
      refute_enqueued(worker: TelegramOutboundWorker)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      # The resume re-established delivery of the SAME persisted reply
      # without generating another one.
      refute_received :generated
      outbound_id = outbound.id
      assert [%Message{id: ^outbound_id}] = messages(patient, "outbound")
      [inbound] = messages(patient, "inbound")
      assert [_one_diagnosis] = diagnoses(inbound.id)

      assert [
               %Oban.Job{
                 queue: "telegram_outbound",
                 args: %{"message_id" => ^outbound_id, "body" => @reply, "chat_id" => @chat_id}
               }
             ] = all_enqueued(worker: TelegramOutboundWorker)
    end
  end

  describe "perform/1 — crisis replies keep their content, priority, and persistence" do
    test "a repeated crisis execution reuses the persisted crisis reply on the crisis lane" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, @crisis_text, telegram_message_id: 600, telegram_update_id: 40)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      [inbound] = messages(patient, "inbound")

      assert [%Message{behavior_type: "crisis_bypass"} = outbound] =
               messages(patient, "outbound")

      assert outbound.reply_to_message_id == inbound.id

      assert [%Diagnosis{model_version: "crisis-bypass", ai_response: @crisis_message}] =
               diagnoses(inbound.id)

      outbound_id = outbound.id

      assert [
               %Oban.Job{
                 queue: "telegram_outbound_crisis",
                 priority: 0,
                 args: %{
                   "message_id" => ^outbound_id,
                   "body" => @crisis_message,
                   "lane" => "crisis"
                 }
               }
             ] = all_enqueued(worker: TelegramOutboundWorker)
    end

    test "a crisis reply persisted without a delivery job is delivered on resume with its persisted content" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, @crisis_text, telegram_message_id: 601, telegram_update_id: 41)
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")

      fail_outbound_enqueue_once()

      assert_raise RuntimeError, ~r/failed to enqueue TelegramOutboundWorker/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      assert [outbound] = messages(patient, "outbound")
      refute_enqueued(worker: TelegramOutboundWorker)
      assert_receive {:crisis_detected, _}

      # The professional edits the crisis message before the retry: the
      # patient must still receive the reply the clinical record holds.
      patient.legacy_patient.professional
      |> Ecto.Changeset.change(%{crisis_message: "Mensaje editado después"})
      |> Repo.update!()

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      outbound_id = outbound.id
      assert [%Message{id: ^outbound_id}] = messages(patient, "outbound")
      [inbound] = messages(patient, "inbound")
      assert [_one_diagnosis] = diagnoses(inbound.id)

      assert [
               %Oban.Job{
                 queue: "telegram_outbound_crisis",
                 priority: 0,
                 args: %{"message_id" => ^outbound_id, "body" => @crisis_message}
               }
             ] = all_enqueued(worker: TelegramOutboundWorker)

      # The psychologist alert is re-raised on resume (at-least-once): a
      # lost crisis alert is worse than a repeated one.
      assert_receive {:crisis_detected, %{level: _, triggers: _}}
    end
  end

  describe "outbound delivery — explicit outcomes on the journaling lane" do
    setup do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 700, telegram_update_id: 50)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
      [job] = all_enqueued(worker: TelegramOutboundWorker)

      %{patient: patient, inbound_args: args, job: job}
    end

    test "a persisted reply starts with a pending delivery", %{patient: patient} do
      assert %Message{delivery_state: "pending", delivered_telegram_message_id: nil} =
               reply(patient)
    end

    test "an acknowledged delivery stores Telegram's message id and is never sent again",
         %{patient: patient, inbound_args: inbound_args, job: job} do
      assert :ok = run_outbound(job)

      assert [%{chat_id: @chat_id, text: @reply, message_id: telegram_id}] = Fake.sends()
      delivered_id = to_string(telegram_id)

      assert %Message{delivery_state: "sent", delivered_telegram_message_id: ^delivered_id} =
               reply(patient)

      # An outbound retry / duplicate execution of the delivery job.
      assert :ok = run_outbound(job)
      assert [_only_one_send] = Fake.sends()

      # A repeated inbound job after the delivery job was pruned must not
      # re-establish delivery of an acknowledged reply.
      Repo.delete_all(Oban.Job)
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: inbound_args})
      refute_enqueued(worker: TelegramOutboundWorker)

      assert %Message{delivery_state: "sent"} = reply(patient)
    end

    for {label, reason} <- [
          {"a timeout after the request was sent", {:ambiguous, :timeout}},
          {"a 5xx from Telegram", {:server_error, 502}}
        ] do
      test "#{label} is recorded as ambiguous and the reply is not resent",
           %{patient: patient, inbound_args: inbound_args, job: job} do
        Fake.queue_responses([{:error, unquote(Macro.escape(reason))}])

        assert :ok = run_outbound(job)

        assert %Message{delivery_state: "ambiguous"} = reply(patient)
        # No retry was scheduled and nothing was dead-lettered: the
        # outcome is unknown, not failed.
        assert [_original_only] = all_enqueued(worker: TelegramOutboundWorker)
        assert Repo.aggregate(OutboundDeadLetter, :count) == 0

        # A re-execution of the delivery job does not call Telegram. The
        # scripted error is consumed, so a second call would succeed and
        # be recorded by the Fake.
        assert :ok = run_outbound(job)
        assert Fake.sends() == []

        # Nor does a repeated inbound job re-establish delivery.
        Repo.delete_all(Oban.Job)
        assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: inbound_args})
        refute_enqueued(worker: TelegramOutboundWorker)

        assert %Message{delivery_state: "ambiguous"} = reply(patient)
      end
    end

    for {label, reason} <- [
          {"a 429 rejection", {:rate_limited, 2}},
          {"a connection that was never established", :network}
        ] do
      test "#{label} precedes the send, so the delivery is retried and then acknowledged",
           %{patient: patient, job: job} do
        Fake.queue_responses([{:error, unquote(Macro.escape(reason))}])

        assert :ok = run_outbound(job)

        assert %Message{delivery_state: "pending"} = reply(patient)
        assert Fake.sends() == []

        assert [retry] =
                 [worker: TelegramOutboundWorker]
                 |> all_enqueued()
                 |> Enum.filter(&(&1.args["_attempt"] == 2))

        assert retry.queue == "telegram_outbound"

        assert :ok = run_outbound(retry)

        assert [%{text: @reply}] = Fake.sends()
        assert %Message{delivery_state: "sent"} = reply(patient)
      end
    end

    test "pre-send failures that exhaust the retry budget end as failed and are not re-established",
         %{patient: patient, inbound_args: inbound_args, job: job} do
      Fake.queue_responses([{:error, {:rate_limited, 1}}])
      exhausted = %{job | args: Map.put(job.args, "_attempt", 5)}

      assert :ok = run_outbound(exhausted)

      assert %Message{delivery_state: "failed"} = reply(patient)
      assert Repo.aggregate(OutboundDeadLetter, :count) == 1

      Repo.delete_all(Oban.Job)
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: inbound_args})
      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "a delivery whose execution died mid-send is ambiguous: its re-execution does not send",
         %{patient: patient, job: job} do
      use_client_mock()

      expect(IdempotencyTelegramClientMock, :send_message, fn @chat_id, @reply ->
        raise "worker node lost while the request was in flight"
      end)

      assert_raise RuntimeError, fn -> run_outbound(job) end

      # The re-execution (Oban rescue of the orphaned job) uses a working
      # client; it must still not send.
      Application.put_env(:alethea, :telegram_client, Fake)

      assert :ok = run_outbound(job)

      assert Fake.sends() == []
      assert %Message{delivery_state: "ambiguous"} = reply(patient)
    end

    test "two concurrent executions of the same delivery job send once",
         %{patient: patient, job: job} do
      use_client_mock()
      test_pid = self()

      # Zero further calls are allowed: a second send would fail the test.
      expect(IdempotencyTelegramClientMock, :send_message, 1, fn @chat_id, @reply ->
        send(test_pid, {:sending, self()})

        receive do
          :acknowledge -> {:ok, 4242}
        after
          5_000 -> {:error, :never_released}
        end
      end)

      first = Task.async(fn -> run_outbound(job) end)
      assert_receive {:sending, in_flight}, 5_000

      # The second execution starts while the first one's request is in
      # flight. It finishes without calling the client.
      assert :ok = Task.await(Task.async(fn -> run_outbound(job) end), 10_000)

      send(in_flight, :acknowledge)
      assert :ok = Task.await(first, 10_000)

      # The acknowledgement of the one real send is the recorded outcome.
      assert %Message{delivery_state: "sent", delivered_telegram_message_id: "4242"} =
               reply(patient)
    end
  end

  describe "outbound delivery — the crisis lane keeps its resend behavior" do
    setup do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, @crisis_text, telegram_message_id: 800, telegram_update_id: 60)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
      [job] = all_enqueued(worker: TelegramOutboundWorker)

      %{patient: patient, job: job}
    end

    test "an ambiguous transport outcome is retried on the crisis lane with its priority",
         %{patient: patient, job: job} do
      Fake.queue_responses([{:error, {:ambiguous, :timeout}}])

      assert :ok = run_outbound(job)

      assert [retry] =
               [worker: TelegramOutboundWorker]
               |> all_enqueued()
               |> Enum.filter(&(&1.args["_attempt"] == 2))

      assert retry.queue == "telegram_outbound_crisis"
      assert retry.priority == 0
      assert retry.args["body"] == @crisis_message

      assert :ok = run_outbound(retry)

      assert [%{text: @crisis_message}] = Fake.sends()
      assert %Message{delivery_state: "sent"} = reply(patient)
    end

    test "an acknowledged crisis delivery is not sent again", %{patient: patient, job: job} do
      assert :ok = run_outbound(job)
      assert :ok = run_outbound(job)

      assert [%{text: @crisis_message}] = Fake.sends()
      assert %Message{delivery_state: "sent"} = reply(patient)
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp phi_reply(message_id) do
    {:ok,
     %{
       response: @reply,
       source_message_id: message_id,
       model_version: "phi-4-mini",
       behavior_type: :elicited
     }}
  end

  defp build_args(chat_id, text, opts) do
    %{
      "telegram_update_id" => Keyword.fetch!(opts, :telegram_update_id),
      "message" => %{
        "message_id" => Keyword.fetch!(opts, :telegram_message_id),
        "date" => 1_700_000_000,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "text" => text
      }
    }
  end

  defp messages(%{legacy_patient: legacy_patient}, direction) do
    Repo.all(
      from(m in Message,
        where: m.patient_id == ^legacy_patient.id and m.direction == ^direction,
        order_by: m.inserted_at
      )
    )
  end

  defp reply(patient) do
    [reply] = messages(patient, "outbound")
    reply
  end

  # Executes a delivery job the way Oban would, against the configured
  # Telegram client.
  defp run_outbound(%Oban.Job{} = job) do
    TelegramOutboundWorker.perform(%Oban.Job{
      args: job.args,
      attempt: 1,
      priority: job.priority
    })
  end

  defp use_client_mock do
    Application.put_env(:alethea, :telegram_client, IdempotencyTelegramClientMock)
  end

  defp diagnoses(inbound_id) do
    Repo.all(from(d in Diagnosis, where: d.message_id == ^inbound_id))
  end

  # Simulates a crash between the reply's commit and its delivery
  # enqueue: the first outbound enqueue fails, later ones reach Oban.
  defp fail_outbound_enqueue_once do
    IdempotencyOutboundEnqueueMock
    |> expect(:insert, fn _changeset -> {:error, :enqueue_crashed} end)
    |> stub(:insert, fn changeset -> Oban.insert(changeset) end)

    Application.put_env(:alethea, :telegram_outbound_enqueue, IdempotencyOutboundEnqueueMock)
    on_exit(fn -> Application.delete_env(:alethea, :telegram_outbound_enqueue) end)
  end

  defp bind_patient(chat_id, crisis_message \\ @crisis_message) do
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
      |> Ecto.Changeset.change(%{crisis_message: crisis_message})
      |> Repo.update!()

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_pro)

    {:ok, legacy_pat} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_pro.id},
        kek
      )

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: ChatIdHash.hash(chat_id, @pepper),
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    %{
      foundation_patient: foundation_pat,
      legacy_patient: Alethea.Accounts.get_patient_with_professional(legacy_pat.id),
      chat_id: chat_id
    }
  end

  defp unique_int, do: System.unique_integer([:positive])
end
