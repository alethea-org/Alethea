defmodule Alethea.Jobs.TelegramBurstReplyWorkerTest do
  @moduledoc """
  Tests for `Alethea.Jobs.TelegramBurstReplyWorker` (#391, S2).

  S2 ships this worker inert — nothing in production arms it yet (S3
  wires the safe path). These tests drive `arm/1` and `perform/1`
  directly, and set up burst members with `Clinical.save_telegram_message/5`
  the same way `test/alethea/clinical_test.exs`'s `list_burst_members/1`
  tests already do (there is no safe-path caller to drive through yet).
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox
  import Ecto.Query
  import Alethea.FoundationTestHelper

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.{TelegramBurstReplyWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias Alethea.Triggers.TriggerFiring

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 555_000_111
  @reply "respuesta de ráfaga"

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    stub(Alethea.AI.PhiWorkerMock, :process, fn %{message_id: mid} -> phi_reply(mid) end)

    :ok
  end

  setup :verify_on_exit!

  # ----------------------------------------------------------------
  # arm/1 — debounce (R1, design AD1)
  # ----------------------------------------------------------------

  describe "arm/1" do
    test "renews the single scheduled job per patient, replacing scheduled_at strictly later" do
      patient = bind_patient()
      args = arm_args(patient)

      assert :ok = TelegramBurstReplyWorker.arm(args)

      [first_job] =
        Repo.all(from j in Oban.Job, where: j.worker == "Alethea.Jobs.TelegramBurstReplyWorker")

      first_id = first_job.id
      first_scheduled_at = first_job.scheduled_at

      assert DateTime.compare(first_scheduled_at, DateTime.utc_now()) == :gt

      Process.sleep(1_100)

      assert :ok = TelegramBurstReplyWorker.arm(args)

      [job] =
        Repo.all(from j in Oban.Job, where: j.worker == "Alethea.Jobs.TelegramBurstReplyWorker")

      assert job.id == first_id,
             "renewal must replace the existing row (same id), not insert a second one"

      assert DateTime.compare(job.scheduled_at, first_scheduled_at) == :gt,
             "renewal must push scheduled_at strictly later"
    end

    test "a job already in the executing state does not block a new scheduled arm" do
      patient = bind_patient()
      args = arm_args(patient)

      assert :ok = TelegramBurstReplyWorker.arm(args)

      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Alethea.Jobs.TelegramBurstReplyWorker"),
        set: [state: "executing"]
      )

      assert :ok = TelegramBurstReplyWorker.arm(args)

      jobs =
        Repo.all(from j in Oban.Job, where: j.worker == "Alethea.Jobs.TelegramBurstReplyWorker")

      assert length(jobs) == 2,
             "an executing job must not block a fresh scheduled job for the same patient (R1)"

      assert Enum.any?(jobs, &(&1.state == "scheduled"))
    end
  end

  # ----------------------------------------------------------------
  # perform/1 — burst coverage and order (R2)
  # ----------------------------------------------------------------

  describe "perform/1 — burst coverage and order" do
    # Trim lever (task 9.1): both edge cases are the same no-op shape —
    # `perform/1` returns `:ok` without ever reaching generation — so
    # one table-driven test covers both instead of two near-identical
    # ones.
    for label <- ["no members", "patient mismatch"] do
      test "#{label}: returns :ok, nothing generated or enqueued" do
        patient = bind_patient()

        args =
          case unquote(label) do
            "no members" ->
              arm_args(patient)

            "patient mismatch" ->
              other = bind_patient(other_chat_id())

              %{
                patient_id: other.foundation_patient.id,
                chat_id: patient.chat_id,
                chat_id_hash: patient.chat_id_hash
              }
          end

        Alethea.AI.PhiWorkerMock |> expect(:process, 0, fn _ -> flunk("must not generate") end)

        assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: args})

        refute_enqueued(worker: TelegramOutboundWorker)
      end
    end

    test "covers every uncovered member in one reply, anchored to the newest, and enqueues delivery in the transaction" do
      patient = bind_patient()
      test_pid = self()

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      members =
        for tg_id <- ["9", "11", "10"] do
          {:ok, inbound} =
            Clinical.save_telegram_message(
              patient.foundation_patient,
              "mensaje #{tg_id}",
              "inbound",
              "spontaneous",
              tg_id
            )

          inbound
        end

      anchor = Enum.find(members, &(&1.telegram_message_id == "11"))

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:request, %{message_id: message_id}}
      assert message_id == anchor.id

      reload = fn m -> Repo.get!(Message, m.id) end
      covering_ids = members |> Enum.map(reload) |> Enum.map(& &1.replied_by_message_id)

      assert [reply_id] = Enum.uniq(covering_ids)
      refute is_nil(reply_id)

      reply = Repo.get!(Message, reply_id)
      assert reply.direction == "outbound"
      assert reply.behavior_type == "elicited"
      assert reply.reply_to_message_id == anchor.id

      diagnosis = Repo.one(from d in Alethea.AI.Diagnosis, where: d.message_id == ^anchor.id)
      assert diagnosis

      assert [%Oban.Job{args: %{"message_id" => ^reply_id, "body" => @reply, "priority" => 9}}] =
               all_enqueued(worker: TelegramOutboundWorker)
    end
  end

  # ----------------------------------------------------------------
  # perform/1 — save-time staleness (R3)
  # ----------------------------------------------------------------

  describe "perform/1 — save-time staleness" do
    test "a newer uncovered inbound arriving during generation rolls back everything and re-arms" do
      patient = bind_patient()
      test_pid = self()

      {:ok, member} =
        Clinical.save_telegram_message(
          patient.foundation_patient,
          "primero",
          "inbound",
          "spontaneous",
          "60"
        )

      stub(Alethea.AI.PhiWorkerMock, :process, fn request ->
        send(test_pid, :generating)

        receive do
          :release ->
            phi_reply(request.message_id)
        after
          5_000 -> {:error, :never_released}
        end
      end)

      task =
        Task.async(fn ->
          TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})
        end)

      assert_receive :generating, 5_000

      {:ok, newer} =
        Clinical.save_telegram_message(
          patient.foundation_patient,
          "segundo, llegó durante la generación",
          "inbound",
          "spontaneous",
          "61"
        )

      send(task.pid, :release)
      assert :ok = Task.await(task, 10_000)

      refute Repo.get!(Message, member.id).replied_by_message_id
      refute Repo.get!(Message, newer.id).replied_by_message_id
      refute Repo.one(from(m in Message, where: m.direction == "outbound"))
      refute Repo.one(from(d in Alethea.AI.Diagnosis, where: true))
      refute_enqueued(worker: TelegramOutboundWorker)

      assert [_rearmed] =
               Repo.all(
                 from j in Oban.Job,
                   where: j.worker == "Alethea.Jobs.TelegramBurstReplyWorker"
               )
    end
  end

  # ----------------------------------------------------------------
  # perform/1 — pending-reply absorption (R11)
  # ----------------------------------------------------------------

  describe "perform/1 — pending-reply absorption" do
    test "a pending ordinary reply is superseded and absorbed into the new burst's coverage" do
      patient = bind_patient()
      test_pid = self()

      {:ok, member_a} =
        Clinical.save_telegram_message(
          patient.foundation_patient,
          "a",
          "inbound",
          "spontaneous",
          "70"
        )

      {:ok, member_b} =
        Clinical.save_telegram_message(
          patient.foundation_patient,
          "b",
          "inbound",
          "spontaneous",
          "71"
        )

      {:ok, pending_r1} =
        Clinical.save_telegram_reply(
          patient.foundation_patient,
          "r1 pendiente",
          "elicited",
          member_b.id,
          nil
        )

      Repo.update_all(from(m in Message, where: m.id in ^[member_a.id, member_b.id]),
        set: [replied_by_message_id: pending_r1.id]
      )

      {:ok, member_c} =
        Clinical.save_telegram_message(
          patient.foundation_patient,
          "c",
          "inbound",
          "spontaneous",
          "72"
        )

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, :generated)
        phi_reply(request.message_id)
      end)

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_received :generated
      refute_received :generated

      assert Repo.get!(Message, pending_r1.id).delivery_state == "superseded"

      r2 = Repo.get!(Message, member_c.id).replied_by_message_id
      refute is_nil(r2)
      assert Repo.get!(Message, member_a.id).replied_by_message_id == r2
      assert Repo.get!(Message, member_b.id).replied_by_message_id == r2
      assert Repo.get!(Message, member_c.id).replied_by_message_id == r2
    end
  end

  # ----------------------------------------------------------------
  # perform/1 — coverage idempotency under overlapping jobs (R6)
  # ----------------------------------------------------------------

  describe "perform/1 — coverage idempotency under overlapping jobs" do
    test "two overlapping executions on the same members produce one reply and one outbound job" do
      patient = bind_patient()
      test_pid = self()

      {:ok, _member} =
        Clinical.save_telegram_message(
          patient.foundation_patient,
          "unico mensaje",
          "inbound",
          "spontaneous",
          "80"
        )

      stub(Alethea.AI.PhiWorkerMock, :process, fn request ->
        send(test_pid, {:generating, self()})

        receive do
          :release -> phi_reply(request.message_id)
        after
          5_000 -> {:error, :never_released}
        end
      end)

      executions =
        for _ <- 1..2 do
          Task.async(fn ->
            TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})
          end)
        end

      assert_receive {:generating, first}, 5_000
      assert_receive {:generating, second}, 5_000
      refute first == second
      send(first, :release)
      send(second, :release)

      assert [:ok, :ok] = Task.await_many(executions, 10_000)

      assert Repo.aggregate(from(m in Message, where: m.direction == "outbound"), :count) == 1

      assert [_one_job] = all_enqueued(worker: TelegramOutboundWorker)
    end
  end

  # ----------------------------------------------------------------
  # perform/1 — reactive triggers (#448)
  #
  # The matcher slot is the deterministic `TriggerMatcher.Fake` (config/
  # test.exs) unless a test binds `TriggerMatcherMock`.
  # ----------------------------------------------------------------

  describe "perform/1 — reactive triggers (#448)" do
    @condition "Pelea con mamá"
    @approved "¿Pudiste usar lo que practicamos para hablar con calma?"

    # select_match/2
    test "a matched trigger reaches the prompt and a firing is linked to the anchor" do
      patient = bind_patient()
      trigger = create_reactive!(patient)
      test_pid = self()

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      member = save_inbound!(patient, "Ayer tuve una pelea con mi mamá", "300")

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:request, %{trigger: @approved}}

      assert [%TriggerFiring{} = firing] = Repo.all(TriggerFiring)
      assert firing.trigger_id == trigger.id
      assert firing.message_id == member.id
      assert firing.status == "fired"

      assert Repo.get!(Message, member.id).behavior_type == "spontaneous"
      refute is_nil(Repo.get!(Message, member.id).replied_by_message_id)
      assert [_delivery] = all_enqueued(worker: TelegramOutboundWorker)
    end

    # select_match/2
    test "a second match within the cooldown does not fire" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)
      test_pid = self()

      stub(Alethea.AI.PhiWorkerMock, :process, fn request ->
        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      save_inbound!(patient, "Tuve una pelea con mi mamá", "310")
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})
      assert_receive {:request, %{trigger: @approved}}

      save_inbound!(patient, "Hoy otra vez pelea con mamá", "311")
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})
      assert_receive {:request, second}
      refute Map.has_key?(second, :trigger)

      assert Repo.aggregate(TriggerFiring, :count) == 1
    end

    test "a matcher error still produces the normal reply, without trigger or firing" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)
      use_mock_matcher()
      test_pid = self()

      expect(Alethea.AI.TriggerMatcherMock, :match, fn _text, _candidates ->
        {:error, :unavailable}
      end)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      save_inbound!(patient, "Tuve una pelea con mi mamá", "320")
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:request, request}
      refute Map.has_key?(request, :trigger)
      assert Repo.aggregate(TriggerFiring, :count) == 0
      assert [_delivery] = all_enqueued(worker: TelegramOutboundWorker)
    end

    test "a matcher timeout still produces the normal reply, without trigger or firing" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)
      use_mock_matcher()
      put_env_for_test(:trigger_match_timeout_ms, 50)
      test_pid = self()

      expect(Alethea.AI.TriggerMatcherMock, :match, fn _text, _candidates ->
        receive do
          :never_sent -> {:ok, %{}}
        end
      end)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      save_inbound!(patient, "Tuve una pelea con mi mamá", "330")
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:request, request}
      refute Map.has_key?(request, :trigger)
      assert Repo.aggregate(TriggerFiring, :count) == 0
      assert [_delivery] = all_enqueued(worker: TelegramOutboundWorker)
    end

    # select_match/2
    test "a withheld model reply records no firing" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)
      test_pid = self()

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, {:request, request})
        {:ok, reply} = phi_reply(request.message_id)
        {:ok, Map.put(reply, :truncated, true)}
      end)

      save_inbound!(patient, "Tuve una pelea con mi mamá", "340")
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:request, %{trigger: @approved}}
      assert Repo.aggregate(TriggerFiring, :count) == 0
    end

    # select_match/2
    test "re-executing a burst with a persisted reply never fires again" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)

      save_inbound!(patient, "Tuve una pelea con mi mamá", "350")
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})
      assert Repo.aggregate(TriggerFiring, :count) == 1

      Alethea.AI.PhiWorkerMock |> expect(:process, 0, fn _ -> flunk("must reuse the reply") end)

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})
      assert Repo.aggregate(TriggerFiring, :count) == 1
    end

    test "sentiment regression: emotion scores reach neither the matcher nor the model" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)
      use_mock_matcher()
      test_pid = self()

      member = save_inbound!(patient, "Estoy muy triste por la pelea con mi mamá", "360")

      Repo.insert!(%Alethea.Clinical.EmotionAnalysis{
        message_id: member.id,
        joy_score: 0.025,
        sadness_score: 0.875,
        anger_score: 0.05,
        fear_score: 0.025,
        neutral_score: 0.025,
        dominant_label: "sadness",
        confidence: 0.875,
        processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      expect(Alethea.AI.TriggerMatcherMock, :match, fn text, candidates ->
        send(test_pid, {:matcher, text, candidates})
        {:ok, %{}}
      end)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:matcher, text, candidates}
      assert text == "Estoy muy triste por la pelea con mi mamá"
      assert_receive {:request, request}

      supplied = inspect({text, candidates, request}, printable_limit: :infinity)
      refute supplied =~ "0.875"
      refute supplied =~ "sadness"
      refute supplied =~ "dominant"
    end

    # select_match/2
    test "a firing committed between match and persist suppresses this burst's firing" do
      patient = bind_patient()
      trigger = create_reactive!(patient)
      test_pid = self()

      # A non-Telegram message: outside every burst, so it cannot make the
      # save transaction stale.
      {:ok, concurrent_anchor} =
        Clinical.save_message(
          patient.legacy_patient,
          "mensaje de otra ráfaga",
          nil,
          "inbound",
          "spontaneous"
        )

      member = save_inbound!(patient, "Ayer tuve una pelea con mi mamá", "370")

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        # Another burst for the same trigger commits its firing after this
        # burst matched (the prompt already carries the trigger) but before
        # this burst persists its reply.
        {:ok, _} =
          Alethea.Triggers.record_reactive_firing(
            trigger.id,
            concurrent_anchor.id,
            DateTime.utc_now()
          )

        send(test_pid, {:request, request})
        phi_reply(request.message_id)
      end)

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:request, %{trigger: @approved}}
      assert [%TriggerFiring{} = firing] = Repo.all(TriggerFiring)
      assert firing.message_id == concurrent_anchor.id

      assert %Message{} = Clinical.get_telegram_reply(member.id)
      assert [_delivery] = all_enqueued(worker: TelegramOutboundWorker)
    end

    # select_match/2
    test "a late-cooldown skip saves the reply and records a content-free audit row" do
      patient = bind_patient()
      trigger = create_reactive!(patient)

      {:ok, concurrent_anchor} =
        Clinical.save_message(
          patient.legacy_patient,
          "mensaje de otra ráfaga",
          nil,
          "inbound",
          "spontaneous"
        )

      member = save_inbound!(patient, "Ayer tuve una pelea con mi mamá", "375")

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn request ->
        {:ok, _} =
          Alethea.Triggers.record_reactive_firing(
            trigger.id,
            concurrent_anchor.id,
            DateTime.utc_now()
          )

        phi_reply(request.message_id)
      end)

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert [%TriggerFiring{message_id: anchor_id}] = Repo.all(TriggerFiring)
      assert anchor_id == concurrent_anchor.id
      assert %Message{} = Clinical.get_telegram_reply(member.id)

      assert [audit] =
               Repo.all(
                 from a in Alethea.Accounts.AuditLog,
                   where: a.action == "trigger_firing_skipped_cooldown"
               )

      assert audit.resource_type == "trigger"
      assert audit.resource_id == trigger.id
      assert audit.professional_id == trigger.professional_id
      assert audit.details == %{}
    end

    # select_match/2
    test "a multi-message burst links the firing to its newest member, stable across re-runs" do
      patient = bind_patient()
      trigger = create_reactive!(patient)

      # Inserted out of Telegram order: the anchor is the newest member by
      # telegram_message_id (the `list_burst_members/1` order), not by
      # insertion time.
      _first = save_inbound!(patient, "Ayer tuve una pelea con mi mamá", "381")
      newest = save_inbound!(patient, "y no pude dormir", "383")
      _middle = save_inbound!(patient, "me sentí muy mal", "382")

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert [%TriggerFiring{} = firing] = Repo.all(TriggerFiring)
      assert firing.trigger_id == trigger.id
      assert firing.message_id == newest.id

      Alethea.AI.PhiWorkerMock |> expect(:process, 0, fn _ -> flunk("must reuse the reply") end)

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert [again] = Repo.all(TriggerFiring)
      assert again.id == firing.id
      assert again.message_id == newest.id

      job_args = Repo.all(from j in Oban.Job, select: j.args)
      refute inspect(job_args, printable_limit: :infinity) =~ @condition
    end

    test "the matcher receives the burst text sanitized" do
      patient = bind_patient()
      _trigger = create_reactive!(patient)
      use_mock_matcher()
      test_pid = self()

      expect(Alethea.AI.TriggerMatcherMock, :match, fn text, candidates ->
        send(test_pid, {:matcher, text, candidates})
        {:ok, %{}}
      end)

      save_inbound!(patient, "Pelea con mamá, escríbele a ana@example.com", "390")
      save_inbound!(patient, "o llámala al +56 9 1234 5678", "391")

      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: arm_args(patient)})

      assert_receive {:matcher, text, [candidate]}
      refute text =~ "ana@example.com"
      refute text =~ "1234 5678"
      assert text =~ "[REDACTED_EMAIL]"
      assert text =~ "[REDACTED_PHONE]"
      assert candidate.condition == @condition
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp create_reactive!(patient) do
    {:ok, trigger} =
      Alethea.Triggers.create_and_approve_reactive_trigger(
        patient.legacy_professional,
        patient.legacy_patient.id,
        %{
          "condition" => @condition,
          "instruction" => "Retomar la comunicación asertiva",
          "approved_text" => @approved
        }
      )

    trigger
  end

  defp save_inbound!(patient, text, telegram_message_id) do
    {:ok, inbound} =
      Clinical.save_telegram_message(
        patient.foundation_patient,
        text,
        "inbound",
        "spontaneous",
        telegram_message_id
      )

    inbound
  end

  defp use_mock_matcher, do: put_env_for_test(:trigger_matcher, Alethea.AI.TriggerMatcherMock)

  defp put_env_for_test(key, value) do
    original = Application.fetch_env!(:alethea, key)
    Application.put_env(:alethea, key, value)
    on_exit(fn -> Application.put_env(:alethea, key, original) end)
  end

  defp phi_reply(message_id) do
    {:ok,
     %{
       response: @reply,
       source_message_id: message_id,
       model_version: "phi-4-mini",
       behavior_type: :elicited
     }}
  end

  defp arm_args(patient) do
    %{
      patient_id: patient.foundation_patient.id,
      chat_id: patient.chat_id,
      chat_id_hash: patient.chat_id_hash
    }
  end

  defp other_chat_id, do: @chat_id + System.unique_integer([:positive])

  defp bind_patient(chat_id \\ @chat_id) do
    chat_id_hash = ChatIdHash.hash(chat_id, @pepper)

    legacy_professional = legacy_professional_fixture()
    legacy_patient = legacy_patient_fixture(legacy_professional)

    foundation_patient =
      professional_fixture()
      |> patient_fixture()
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: chat_id_hash,
        legacy_patient_id: legacy_patient.id
      })
      |> Repo.update!()

    %{
      foundation_patient: foundation_patient,
      legacy_professional: legacy_professional,
      legacy_patient: legacy_patient,
      chat_id: chat_id,
      chat_id_hash: chat_id_hash
    }
  end
end
