defmodule AletheaJobs.ActiveTriggerDailyCapTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}
  alias AletheaJobs.ActiveTriggerWorker

  setup do
    fixture = fixture_professional_and_patient()
    Repo.delete_all(Oban.Job)

    on_exit(fn ->
      Application.delete_env(:alethea, :active_trigger_daily_cap)
    end)

    fixture
  end

  defp create_due_trigger(fixture, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    due = Map.get(attrs, :scheduled_at, now)

    base_attrs = %{
      instruction: "Recordatorio",
      approved_text: "Mensaje de recordatorio",
      date: DateTime.to_date(due) |> Date.add(1),
      time: ~T[10:00:00]
    }

    merged = Map.merge(base_attrs, attrs)

    {:ok, trigger} =
      Triggers.create_and_approve_trigger(fixture.professional, fixture.patient.id, merged)

    trigger =
      trigger
      |> Ecto.Changeset.change(scheduled_at: due)
      |> Repo.update!()

    Repo.delete_all(Oban.Job)
    trigger
  end

  defp insert_firing!(trigger, scheduled_at, fired_at, status) do
    now_sec = DateTime.truncate(fired_at, :second)

    message_id =
      if status == "fired" do
        message =
          %Message{}
          |> Message.changeset(%{
            patient_id: trigger.patient_id,
            direction: "outbound",
            behavior_type: "spontaneous",
            encrypted_content: trigger.approved_text,
            timestamp: now_sec
          })
          |> Ecto.Changeset.put_change(:delivery_state, "sent")
          |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
          |> Repo.insert!()

        message.id
      else
        nil
      end

    %TriggerFiring{}
    |> TriggerFiring.changeset(%{
      trigger_id: trigger.id,
      message_id: message_id,
      status: status,
      fired_at: now_sec,
      scheduled_at: scheduled_at
    })
    |> Repo.insert!()
  end

  describe "daily cap (S2, S4)" do
    test "5th send of the day fires normally", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 4 previous sends today
      for i <- 1..4 do
        t = create_due_trigger(ctx)
        past_time = DateTime.add(now, -i * 300, :second)
        insert_firing!(t, past_time, past_time, "fired")
      end

      trigger5 = create_due_trigger(ctx, %{scheduled_at: now})

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger5.id})

      firing5 = Repo.get_by!(TriggerFiring, trigger_id: trigger5.id)
      assert firing5.status == "fired"
      assert firing5.message_id != nil
      assert Repo.get!(Message, firing5.message_id)
      assert Repo.get!(Trigger, trigger5.id).status == "fired"
      assert_enqueued(worker: TelegramOutboundWorker, args: %{"message_id" => firing5.message_id})
    end

    test "6th send of the day is skipped without message or outbound job", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..5 do
        t = create_due_trigger(ctx)
        past_time = DateTime.add(now, -i * 300, :second)
        insert_firing!(t, past_time, past_time, "fired")
      end

      msg_count_before = Repo.aggregate(Message, :count)

      trigger6 = create_due_trigger(ctx, %{scheduled_at: now})

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger6.id})

      # No message created
      assert Repo.aggregate(Message, :count) == msg_count_before

      # No outbound job enqueued
      refute_enqueued(worker: TelegramOutboundWorker)

      # Skipped firing recorded
      firing6 = Repo.get_by!(TriggerFiring, trigger_id: trigger6.id)
      assert firing6.status == "skipped"
      assert is_nil(firing6.message_id)
      assert firing6.scheduled_at == trigger6.scheduled_at

      # Trigger lifecycle consumed for one-shot (status "fired")
      assert Repo.get!(Trigger, trigger6.id).status == "fired"

      # Content-free audit log recorded
      assert Repo.get_by(AuditLog,
               resource_id: trigger6.id,
               action: "trigger_skipped",
               resource_type: "trigger"
             )

      # Idempotent re-run does not create duplicate firing
      firings_count = Repo.aggregate(TriggerFiring, :count)
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger6.id})
      assert Repo.aggregate(TriggerFiring, :count) == firings_count
    end

    test "skipped recurring trigger advances to next occurrence", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..5 do
        t = create_due_trigger(ctx)
        past_time = DateTime.add(now, -i * 300, :second)
        insert_firing!(t, past_time, past_time, "fired")
      end

      # Create a daily recurring trigger
      patient = ctx.patient

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(ctx.professional, patient.id, %{
          instruction: "Recordatorio diario",
          approved_text: "Mensaje diario",
          schedule_type: "daily",
          time: "10:00"
        })

      # Force scheduled_at to now so it's due
      trigger =
        trigger
        |> Ecto.Changeset.change(scheduled_at: now)
        |> Repo.update!()

      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Skipped firing recorded
      firing = Repo.get_by!(TriggerFiring, trigger_id: trigger.id)
      assert firing.status == "skipped"
      assert is_nil(firing.message_id)

      # Trigger remains active and advanced to next occurrence (tomorrow)
      updated_trigger = Repo.get!(Trigger, trigger.id)
      assert updated_trigger.status == "active"
      assert DateTime.compare(updated_trigger.scheduled_at, now) == :gt

      # Next Oban job scheduled
      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id},
        scheduled_at: updated_trigger.scheduled_at
      )
    end

    test "per-patient isolation: 5 sends for patient A do not cap patient B", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 5 sends for Patient A (ctx.patient)
      for i <- 1..5 do
        t = create_due_trigger(ctx)
        past_time = DateTime.add(now, -i * 300, :second)
        insert_firing!(t, past_time, past_time, "fired")
      end

      # Patient B with own trigger
      patient_int = unique_int()

      patient_attrs = %{
        "alias" => "Paciente #{patient_int}",
        "professional_id" => ctx.professional.id,
        "timezone" => "America/Santiago"
      }

      {:ok, patient_b} = Alethea.Accounts.create_patient(patient_attrs, ctx.kek)

      {:ok, trigger_b} =
        Triggers.create_and_approve_trigger(ctx.professional, patient_b.id, %{
          instruction: "Para paciente B",
          approved_text: "Hola B",
          date: DateTime.to_date(now) |> Date.add(1),
          time: ~T[10:00:00]
        })

      trigger_b =
        trigger_b
        |> Ecto.Changeset.change(scheduled_at: now)
        |> Repo.update!()

      Repo.delete_all(Oban.Job)

      # Patient B fires normally
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger_b.id})

      firing_b = Repo.get_by!(TriggerFiring, trigger_id: trigger_b.id)
      assert firing_b.status == "fired"
      assert firing_b.message_id != nil

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{"message_id" => firing_b.message_id}
      )
    end

    test "configurable cap overrides default 5", ctx do
      Application.put_env(:alethea, :active_trigger_daily_cap, 2)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 2 sends today
      for i <- 1..2 do
        t = create_due_trigger(ctx)
        past_time = DateTime.add(now, -i * 300, :second)
        insert_firing!(t, past_time, past_time, "fired")
      end

      trigger3 = create_due_trigger(ctx, %{scheduled_at: now})

      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger3.id})

      firing3 = Repo.get_by!(TriggerFiring, trigger_id: trigger3.id)
      assert firing3.status == "skipped"
      assert is_nil(firing3.message_id)
    end

    test "calendar day boundary uses patient timezone, not UTC or trigger timezone", ctx do
      # Set patient timezone to America/Santiago
      {:ok, patient} =
        Alethea.Accounts.update_patient(ctx.patient, %{timezone: "America/Santiago"})

      ctx = Map.put(ctx, :patient, patient)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 5 sends occurred yesterday in patient's local timezone (e.g. 28 hours ago)
      yesterday_utc = DateTime.add(now, -28 * 3600, :second)

      for _ <- 1..5 do
        t = create_due_trigger(ctx)
        insert_firing!(t, yesterday_utc, yesterday_utc, "fired")
      end

      # Today's due trigger
      today_trigger = create_due_trigger(ctx, %{scheduled_at: now})

      # Trigger record itself might have another snapshot timezone, but patient timezone is authoritative
      today_trigger
      |> Ecto.Changeset.change(timezone: "Pacific/Auckland")
      |> Repo.update!()

      # Should fire normally because yesterday's 5 sends were on a different patient calendar day
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => today_trigger.id})

      firing = Repo.get_by!(TriggerFiring, trigger_id: today_trigger.id)
      assert firing.status == "fired"
      assert firing.message_id != nil
    end

    test "DST midnight gap in America/Santiago correctly counts firings at the last second of the local day (S2)",
         ctx do
      {:ok, patient} =
        Alethea.Accounts.update_patient(ctx.patient, %{timezone: "America/Santiago"})

      # On 2026-09-06 at midnight in America/Santiago, clock jumps from 00:00 to 01:00 (DST gap).
      # The last second of 2026-09-05 is 23:59:59-04:00, which in UTC is 2026-09-06T03:59:59Z.
      last_second_utc = ~U[2026-09-06 03:59:59Z]
      sept6_start_utc = ~U[2026-09-06 04:00:00Z]

      # Assert contiguous day ranges at 04:00:00Z
      {sept5_start, sept5_end} = Triggers.local_day_utc_range(last_second_utc, patient.timezone)
      {sept6_start, sept6_end} = Triggers.local_day_utc_range(sept6_start_utc, patient.timezone)

      assert sept5_start == ~U[2026-09-05 04:00:00Z]
      assert sept5_end == ~U[2026-09-06 04:00:00Z]
      assert sept6_start == ~U[2026-09-06 04:00:00Z]
      assert DateTime.compare(sept6_end, sept6_start) == :gt

      # Insert 5 real fired records for patient during Sept 5 in local time,
      # with the 5th firing specifically at the last second (2026-09-06T03:59:59Z).
      for i <- 1..4 do
        t = create_due_trigger(ctx)
        past = DateTime.add(last_second_utc, -i * 3600, :second)
        insert_firing!(t, past, past, "fired")
      end

      t5 = create_due_trigger(ctx)
      insert_firing!(t5, last_second_utc, last_second_utc, "fired")

      # Public count_daily_active_sends must find all 5 firings for the Sept 5 calendar day
      assert Triggers.count_daily_active_sends(patient.id, last_second_utc, patient.timezone) == 5

      # On the next day (starting at 04:00:00Z), the count resets to 0
      assert Triggers.count_daily_active_sends(patient.id, sept6_start_utc, patient.timezone) == 0
    end

    test "concurrent independent triggers for same patient serialize without race", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 4 sends already done today
      for i <- 1..4 do
        t = create_due_trigger(ctx)
        past_time = DateTime.add(now, -i * 300, :second)
        insert_firing!(t, past_time, past_time, "fired")
      end

      # 2 independent triggers due concurrently for same patient
      t5 = create_due_trigger(ctx, %{instruction: "T5", scheduled_at: now})
      t6 = create_due_trigger(ctx, %{instruction: "T6", scheduled_at: now})

      parent = self()

      # Run both workers concurrently via Task
      task1 =
        Task.async(fn ->
          send(parent, {:task1_started, self()})
          perform_job(ActiveTriggerWorker, %{"trigger_id" => t5.id})
        end)

      task2 =
        Task.async(fn ->
          send(parent, {:task2_started, self()})
          perform_job(ActiveTriggerWorker, %{"trigger_id" => t6.id})
        end)

      assert_receive {:task1_started, _}
      assert_receive {:task2_started, _}

      res1 = Task.await(task1, 10_000)
      res2 = Task.await(task2, 10_000)

      assert res1 == :ok
      assert res2 == :ok

      f5 = Repo.get_by!(TriggerFiring, trigger_id: t5.id)
      f6 = Repo.get_by!(TriggerFiring, trigger_id: t6.id)

      # Exactly one must be fired (5th) and exactly one must be skipped (6th)
      statuses = Enum.sort([f5.status, f6.status])
      assert statuses == ["fired", "skipped"]

      # Exactly one message created for the fired one
      messages = Repo.all(Ecto.Query.from(m in Message, where: m.trigger_id in ^[t5.id, t6.id]))
      assert length(messages) == 1
    end
  end
end
