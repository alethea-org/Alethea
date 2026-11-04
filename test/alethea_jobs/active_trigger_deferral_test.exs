defmodule AletheaJobs.ActiveTriggerDeferralTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures

  alias Alethea.Clinical.{Message, SessionManager}
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}
  alias AletheaJobs.ActiveTriggerWorker

  setup do
    fixture = fixture_professional_and_patient()

    {:ok, trigger} =
      Triggers.create_and_approve_trigger(fixture.professional, fixture.patient.id, %{
        instruction: "Recordar herramienta",
        approved_text: "Recordá tu herramienta.",
        date: Date.add(Date.utc_today(), 1),
        time: ~T[10:00:00]
      })

    due = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
    trigger = trigger |> Ecto.Changeset.change(scheduled_at: due) |> Repo.update!()
    Repo.delete_all(Oban.Job)
    Map.put(fixture, :trigger, trigger)
  end

  test "open session snoozes without side effects and closure releases the firing", ctx do
    {:ok, session} = SessionManager.open_session(ctx.patient)
    assert_deferred(ctx.trigger)
    {:ok, _} = SessionManager.close_session(session)
    assert_fired(ctx.trigger)
  end

  test "pending burst input defers even without an open session", ctx do
    inbound =
      %Message{}
      |> Message.changeset(%{
        patient_id: ctx.patient.id,
        direction: "inbound",
        encrypted_content: ctx.trigger.approved_text,
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
        telegram_message_id: "444"
      })
      |> Repo.insert!()

    assert_deferred(ctx.trigger)
    # Public coverage API resolves the pending burst without changing session state.
    assert 1 = Alethea.Clinical.cover_members([inbound.id], inbound.id)
    assert_fired(ctx.trigger)
  end

  test "pending burst output defers until it is delivered", ctx do
    reply =
      %Message{}
      |> Message.changeset(%{
        patient_id: ctx.patient.id,
        direction: "outbound",
        behavior_type: "elicited",
        encrypted_content: ctx.trigger.approved_text,
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Ecto.Changeset.put_change(:delivery_state, "pending")
      |> Repo.insert!()

    assert_deferred(ctx.trigger)
    reply |> Ecto.Changeset.change(delivery_state: "sent") |> Repo.update!()
    assert_fired(ctx.trigger)
  end

  test "snooze never extends the original one-hour deadline", ctx do
    {:ok, _} = SessionManager.open_session(ctx.patient)
    due = DateTime.utc_now() |> DateTime.add(-3590, :second) |> DateTime.truncate(:second)
    trigger = ctx.trigger |> Ecto.Changeset.change(scheduled_at: due) |> Repo.update!()
    assert {:snooze, delay} = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})
    assert delay in 1..10
    assert Repo.get!(Trigger, trigger.id).scheduled_at == due
    assert Repo.aggregate(TriggerFiring, :count) == 0
    refute_enqueued(worker: TelegramOutboundWorker)
  end

  test "at one hour a firing proceeds despite an open session and pending input", ctx do
    {:ok, _} = SessionManager.open_session(ctx.patient)
    due = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    trigger = ctx.trigger |> Ecto.Changeset.change(scheduled_at: due) |> Repo.update!()
    assert_fired(trigger)
  end

  test "one-hour ceiling does not bypass crisis protection", ctx do
    {:ok, _} = SessionManager.open_session(ctx.patient)
    due = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    trigger = ctx.trigger |> Ecto.Changeset.change(scheduled_at: due) |> Repo.update!()
    ctx.patient |> Ecto.Changeset.change(urgent_intervention: true) |> Repo.update!()

    assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})
    assert Repo.get!(Trigger, trigger.id).status == "paused_by_crisis"
    assert Repo.aggregate(TriggerFiring, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    refute_enqueued(worker: TelegramOutboundWorker)
  end

  defp assert_deferred(trigger) do
    before = {Repo.aggregate(Message, :count), Repo.aggregate(Alethea.Accounts.AuditLog, :count)}
    assert {:snooze, delay} = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})
    assert delay in 1..60
    assert Repo.get!(Trigger, trigger.id).status == "active"
    assert Repo.get!(Trigger, trigger.id).scheduled_at == trigger.scheduled_at
    assert Repo.aggregate(TriggerFiring, :count) == 0

    assert {Repo.aggregate(Message, :count), Repo.aggregate(Alethea.Accounts.AuditLog, :count)} ==
             before

    refute_enqueued(worker: TelegramOutboundWorker)
  end

  defp assert_fired(trigger) do
    assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})
    firing = Repo.get_by!(TriggerFiring, trigger_id: trigger.id)
    assert firing.status == "fired"
    assert firing.scheduled_at == trigger.scheduled_at
    assert Repo.get!(Message, firing.message_id).trigger_id == trigger.id
    assert Repo.get!(Trigger, trigger.id).status == "fired"
    assert_enqueued(worker: TelegramOutboundWorker, args: %{"message_id" => firing.message_id})
  end
end
