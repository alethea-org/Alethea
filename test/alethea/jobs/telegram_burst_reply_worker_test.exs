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
      legacy_patient: legacy_patient,
      chat_id: chat_id,
      chat_id_hash: chat_id_hash
    }
  end
end
