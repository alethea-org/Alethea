defmodule AletheaJobs.ActiveTriggerWorkerTest do
  @moduledoc """
  Tests for `AletheaJobs.ActiveTriggerWorker` (issue #440, S3/S6/S7/S8).
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Telegram.{Client.Fake, Pacer}
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}
  alias AletheaJobs.ActiveTriggerWorker

  setup do
    {:ok, _} = safe_start_pacer()

    start_supervised!(Fake)
    Fake.reset()
    Application.put_env(:alethea, :telegram_client, Fake)

    Repo.delete_all(Oban.Job)
    Repo.delete_all(AuditLog)

    fixture_professional_and_patient()
  end

  defp safe_start_pacer do
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

    Pacer.start_link([])
  end

  describe "Oban worker contract" do
    test "uses schedulers queue and unique trigger_id across active states" do
      assert ActiveTriggerWorker.__opts__()[:queue] == :schedulers
      assert ActiveTriggerWorker.__opts__()[:max_attempts] == 1

      assert ActiveTriggerWorker.__opts__()[:unique] == [
               keys: [:trigger_id],
               states: [:scheduled, :available, :retryable]
             ]
    end
  end

  describe "perform/1" do
    test "early invocation before scheduled_at snoozes with strictly positive delay and mutates nothing (B1)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar hidratación",
          approved_text: "Hola! Recuerda beber agua hoy.",
          date: future_date,
          time: ~T[10:00:00]
        })

      Repo.delete_all(Oban.Job)

      # Invoking perform early must snooze
      assert {:snooze, delay} = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})
      assert is_integer(delay) and delay > 0

      # Trigger must remain active
      assert Repo.get!(Trigger, trigger.id).status == "active"

      # No message, firing, audit log, or outbound job created
      assert Repo.aggregate(Message, :count, :id) == 0
      assert Repo.aggregate(TriggerFiring, :count, :id) == 0

      assert Repo.aggregate(
               Ecto.Query.from(a in AuditLog, where: a.action == "trigger_fired"),
               :count,
               :id
             ) == 0

      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "due invocation of daily trigger: advances scheduled_at, keeps status active, enqueues next Oban job",
         %{professional: professional, patient: patient} do
      time = ~T[10:00:00]
      end_date = Date.utc_today() |> Date.add(10)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          schedule_type: "daily",
          time: time,
          end_date: end_date,
          instruction: "Recordar tarea diaria",
          approved_text: "Hola! ¿Completaste tu tarea diaria?"
        })

      # Set scheduled_at to due (past instant) in isolated state
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger =
        trigger
        |> Ecto.Changeset.change(%{scheduled_at: due_at})
        |> Repo.update!()

      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Trigger must remain "active" with scheduled_at advanced to next day
      updated_trigger = Repo.get!(Trigger, trigger.id)
      assert updated_trigger.status == "active"
      assert DateTime.compare(updated_trigger.scheduled_at, due_at) == :gt

      # Firing record exists with scheduled_at equal to due_at
      firing =
        Repo.get_by!(TriggerFiring, trigger_id: trigger.id, scheduled_at: due_at)

      assert firing.status == "fired"

      # Next ActiveTriggerWorker Oban job is enqueued for updated_trigger.scheduled_at
      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id}
      )

      [next_job] =
        Repo.all(
          Ecto.Query.from(j in Oban.Job,
            where: j.worker == "AletheaJobs.ActiveTriggerWorker" and j.state == "scheduled"
          )
        )

      assert DateTime.compare(next_job.scheduled_at, updated_trigger.scheduled_at) == :eq
    end

    test "due invocation of daily trigger on end_date: fires, transitions status to fired, enqueues no more jobs",
         %{professional: professional, patient: patient} do
      # Initial occurrence created for future
      end_date = Date.utc_today() |> Date.add(1)
      time = ~T[10:00:00]

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          schedule_type: "daily",
          time: time,
          end_date: end_date,
          instruction: "Último recordatorio",
          approved_text: "Hola! Este es el último recordatorio de tu tarea."
        })

      # Simulate that trigger is due today and end_date is today:
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
      {:ok, local_due} = DateTime.shift_zone(due_at, trigger.timezone, Tz.TimeZoneDatabase)
      today_local = DateTime.to_date(local_due)

      trigger =
        trigger
        |> Ecto.Changeset.change(%{scheduled_at: due_at, end_date: today_local})
        |> Repo.update!()

      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Trigger status transitioned to "fired" because end_date was reached
      updated_trigger = Repo.get!(Trigger, trigger.id)
      assert updated_trigger.status == "fired"

      # Trigger firing recorded
      firing =
        Repo.get_by!(TriggerFiring, trigger_id: trigger.id)

      assert firing.status == "fired"

      # NO next ActiveTriggerWorker job is scheduled
      refute_enqueued(worker: ActiveTriggerWorker)
    end

    test "due invocation of weekly trigger: advances scheduled_at to next weekday and enqueues next job",
         %{professional: professional, patient: patient} do
      time = ~T[15:00:00]
      weekdays = [1, 2, 3, 4, 5, 6, 7]

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          schedule_type: "weekly",
          time: time,
          weekdays: weekdays,
          instruction: "Recordatorio semanal",
          approved_text: "Hola! Recordatorio semanal."
        })

      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger =
        trigger
        |> Ecto.Changeset.change(%{scheduled_at: due_at})
        |> Repo.update!()

      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Trigger remains active and next job scheduled
      updated_trigger = Repo.get!(Trigger, trigger.id)
      assert updated_trigger.status == "active"
      assert DateTime.compare(updated_trigger.scheduled_at, due_at) == :gt

      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id}
      )
    end

    test "due invocation fires active trigger: creates message, firing, audit log, updates status, and enqueues TelegramOutboundWorker (B1, B4, B5)",
         %{professional: professional, patient: patient, foundation_patient: foundation_patient} do
      chat_id = 987_654_321
      chat_id_hash = String.duplicate("c", 64)

      foundation_patient =
        foundation_patient
        |> Ecto.Changeset.change(%{telegram_chat_id_hash: chat_id_hash})
        |> Repo.update!()

      {:ok, _} =
        Alethea.Foundation.Accounts.store_encrypted_telegram_chat_id(
          foundation_patient,
          chat_id
        )

      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar hidratación",
          approved_text: "Hola! Recuerda beber agua hoy.",
          date: future_date,
          time: ~T[10:00:00]
        })

      # Set scheduled_at to due (past instant) in isolated state
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger =
        trigger
        |> Ecto.Changeset.change(%{scheduled_at: due_at})
        |> Repo.update!()

      # Clear the scheduled job created by trigger creation so we can isolate perform/1
      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Trigger status updated to fired
      updated_trigger = Repo.get!(Trigger, trigger.id)
      assert updated_trigger.status == "fired"

      # Trigger firing created with status "fired" (not "sent") (B4)
      firing = Repo.get_by!(TriggerFiring, trigger_id: trigger.id)
      assert firing.status == "fired"
      assert firing.message_id != nil

      # Message created with trigger_id and pending delivery
      message = Repo.get!(Message, firing.message_id)
      assert message.trigger_id == trigger.id
      assert message.patient_id == patient.id
      assert message.direction == "outbound"
      assert message.behavior_type == "spontaneous"
      assert message.delivery_state == "pending"

      # Content matches encrypted approved text
      assert message.encrypted_content == trigger.approved_text

      # Outbound worker enqueued with IDs only
      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{
          "trigger_id" => trigger.id,
          "message_id" => message.id,
          "lane" => "trigger"
        }
      )

      # Content-free audit log for firing
      audit =
        Repo.get_by(AuditLog,
          resource_id: trigger.id,
          action: "trigger_fired",
          professional_id: professional.id
        )

      assert audit != nil
      assert audit.details == %{} or audit.details == nil

      # Executing the outbound job delivers through Fake client (S7)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :telegram_outbound)
      assert [%{chat_id: ^chat_id, text: "Hola! Recuerda beber agua hoy."}] = Fake.sends()
      assert Repo.get!(Message, message.id).delivery_state == "sent"

      # History lists firing linked to message (S8)
      assert {:ok, [history_firing]} = Triggers.list_firings(professional, patient.id)
      assert history_firing.id == firing.id
      assert history_firing.message_id == message.id
      assert history_firing.trigger.id == trigger.id
    end

    test "duplicate / replayed execution is idempotent: does not duplicate firing, message, or outbound job (B3)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar hidratación",
          approved_text: "Hola! Recuerda beber agua hoy.",
          date: future_date,
          time: ~T[10:00:00]
        })

      # Make it due now
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger =
        trigger
        |> Ecto.Changeset.change(%{scheduled_at: due_at})
        |> Repo.update!()

      Repo.delete_all(Oban.Job)

      # First run
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})
      messages_count = Repo.aggregate(Message, :count, :id)
      firings_count = Repo.aggregate(TriggerFiring, :count, :id)

      outbound_jobs_count =
        Repo.aggregate(
          Ecto.Query.from(j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker"
          ),
          :count,
          :id
        )

      assert messages_count == 1
      assert firings_count == 1
      assert outbound_jobs_count == 1

      # Second run (replayed)
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      assert Repo.aggregate(Message, :count, :id) == messages_count
      assert Repo.aggregate(TriggerFiring, :count, :id) == firings_count

      assert Repo.aggregate(
               Ecto.Query.from(j in Oban.Job,
                 where: j.worker == "Alethea.Jobs.TelegramOutboundWorker"
               ),
               :count,
               :id
             ) == outbound_jobs_count
    end

    test "concurrent execution of perform/1 for same trigger_id executes once and serializes cleanly (B3)" do
      # Fixture created in unboxed_run so multiple sandbox connections see it
      {professional, patient, trigger} =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          fixture = fixture_professional_and_patient()
          future_date = Date.utc_today() |> Date.add(1)

          {:ok, trigger} =
            Triggers.create_and_approve_trigger(fixture.professional, fixture.patient.id, %{
              instruction: "Instruccion concurrente",
              approved_text: "Texto concurrente",
              date: future_date,
              time: ~T[10:00:00]
            })

          due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

          trigger =
            trigger
            |> Ecto.Changeset.change(%{scheduled_at: due_at})
            |> Repo.update!()

          {fixture.professional, fixture.patient, trigger}
        end)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DELETE FROM oban_jobs WHERE args->>'trigger_id' = $1", [trigger.id])

          # #452: trigger_saved / trigger_firing_created RAG outbox jobs carry
          # resource_id/patient_id (no trigger_id) — scope by patient so the
          # committed rows never leak into later refute_enqueued assertions.
          Repo.query!(
            "DELETE FROM oban_jobs WHERE worker = 'AletheaJobs.ClinicalRecordOutboxWorker' AND args->>'patient_id' = $1",
            [patient.id]
          )

          Repo.query!("DELETE FROM trigger_firings WHERE trigger_id = $1", [
            Ecto.UUID.dump!(trigger.id)
          ])

          Repo.query!("DELETE FROM messages WHERE trigger_id = $1", [Ecto.UUID.dump!(trigger.id)])
          Repo.query!("DELETE FROM triggers WHERE id = $1", [Ecto.UUID.dump!(trigger.id)])

          Repo.query!("DELETE FROM audit_logs WHERE professional_id = $1", [
            Ecto.UUID.dump!(professional.id)
          ])

          Repo.query!("DELETE FROM foundation_patients WHERE legacy_patient_id = $1", [
            Ecto.UUID.dump!(patient.id)
          ])

          Repo.query!("DELETE FROM patients WHERE id = $1", [Ecto.UUID.dump!(patient.id)])

          Repo.query!("DELETE FROM foundation_professionals WHERE legacy_professional_id = $1", [
            Ecto.UUID.dump!(professional.id)
          ])

          Repo.query!("DELETE FROM professionals WHERE id = $1", [
            Ecto.UUID.dump!(professional.id)
          ])
        end)
      end)

      task_supervisor = start_supervised!(Task.Supervisor)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

            try do
              send(parent, {:worker_ready, self()})

              receive do
                :fire ->
                  ActiveTriggerWorker.perform(%Oban.Job{args: %{"trigger_id" => trigger.id}})
              end
            after
              Ecto.Adapters.SQL.Sandbox.checkin(Repo)
            end
          end)
        end

      pids =
        Enum.map(tasks, fn _ ->
          receive do
            {:worker_ready, pid} -> pid
          end
        end)

      Enum.each(pids, &send(&1, :fire))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.all?(results, &(&1 == :ok))

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(
                 Ecto.Query.from(m in Message, where: m.trigger_id == ^trigger.id),
                 :count,
                 :id
               ) == 1

        assert Repo.aggregate(
                 Ecto.Query.from(f in TriggerFiring, where: f.trigger_id == ^trigger.id),
                 :count,
                 :id
               ) == 1

        assert Repo.aggregate(
                 Ecto.Query.from(a in AuditLog,
                   where: a.resource_id == ^trigger.id and a.action == "trigger_fired"
                 ),
                 :count,
                 :id
               ) == 1

        assert Repo.aggregate(
                 Ecto.Query.from(j in Oban.Job,
                   where:
                     j.args["trigger_id"] == ^trigger.id and
                       j.worker == "Alethea.Jobs.TelegramOutboundWorker"
                 ),
                 :count,
                 :id
               ) == 1
      end)
    end

    test "concurrent early invocation returns snooze without mutations (B3)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(3)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar temprano",
          approved_text: "Mensaje temprano",
          date: future_date,
          time: ~T[12:00:00]
        })

      Repo.delete_all(Oban.Job)

      task_supervisor = start_supervised!(Task.Supervisor)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            send(parent, {:worker_ready, self()})

            receive do
              :check ->
                ActiveTriggerWorker.perform(%Oban.Job{args: %{"trigger_id" => trigger.id}})
            end
          end)
        end

      pids =
        Enum.map(tasks, fn _ ->
          receive do
            {:worker_ready, pid} -> pid
          end
        end)

      Enum.each(pids, &send(&1, :check))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.all?(results, fn
               {:snooze, delay} when is_integer(delay) and delay > 0 -> true
               _ -> false
             end)

      assert Repo.aggregate(Message, :count, :id) == 0
      assert Repo.aggregate(TriggerFiring, :count, :id) == 0
    end

    test "ignores nonexistent trigger id without creating anything" do
      fake_id = Ecto.UUID.generate()
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => fake_id})

      assert Repo.aggregate(Message, :count, :id) == 0
      assert Repo.aggregate(TriggerFiring, :count, :id) == 0
    end
  end
end
