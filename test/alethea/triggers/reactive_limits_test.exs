defmodule Alethea.Triggers.ReactiveLimitsTest do
  @moduledoc """
  Reactive trigger cooldown editing, fire-once and the per-patient limit of
  active reactive triggers (#450).
  """

  use Alethea.DataCase, async: false

  import Alethea.TriggersFixtures

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}

  @condition "Habla de una discusión con su madre"
  @instruction "Retomar el ejercicio de comunicación asertiva"
  @approved "¿Te sirvió practicar lo que conversamos sobre comunicarte con calma?"

  setup do
    fixture_professional_and_patient()
  end

  describe "fire-once on creation (S1, S6)" do
    test "a reactive trigger is not fire-once by default and keeps the 24h cooldown",
         %{professional: professional, patient: patient} do
      assert {:ok, trigger} = create_reactive(professional, patient)

      assert trigger.fire_once == false
      assert trigger.cooldown_hours == 24
      assert %Trigger{fire_once: false, cooldown_hours: 24} = Repo.get!(Trigger, trigger.id)
    end

    test "accepts fire-once and a cooldown from form params",
         %{professional: professional, patient: patient} do
      assert {:ok, trigger} =
               create_reactive(professional, patient, %{
                 "fire_once" => "true",
                 "cooldown_hours" => "6"
               })

      assert %Trigger{fire_once: true, cooldown_hours: 6} = Repo.get!(Trigger, trigger.id)
    end
  end

  describe "fire-once firing (S2)" do
    test "a fire-once trigger fires once and then is inactive",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient, %{"fire_once" => "true"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, %TriggerFiring{}} =
               Triggers.fire_reactive_trigger(trigger.id, inbound_message(patient).id, now)

      assert %Trigger{status: "inactive"} = Repo.get!(Trigger, trigger.id)

      assert [%AuditLog{details: details, professional_id: professional_id}] =
               audits(trigger.id, "trigger_deactivated_fire_once")

      assert details == %{}
      assert professional_id == professional.id

      # Never offered to the matcher again, even once its cooldown has elapsed.
      assert {:ok, []} =
               Triggers.eligible_reactive_triggers(patient, DateTime.add(now, 48, :hour))

      assert {:ok, :skipped} =
               Triggers.fire_reactive_trigger(
                 trigger.id,
                 inbound_message(patient).id,
                 DateTime.add(now, 48, :hour)
               )

      assert Repo.aggregate(TriggerFiring, :count) == 1
    end

    test "a trigger that is not fire-once stays active after firing",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, %TriggerFiring{}} =
               Triggers.fire_reactive_trigger(trigger.id, inbound_message(patient).id, now)

      assert %Trigger{status: "active"} = Repo.get!(Trigger, trigger.id)
      assert audits(trigger.id, "trigger_deactivated_fire_once") == []
    end
  end

  describe "update_reactive_trigger/4 (S1, S3, S5)" do
    setup %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      %{trigger: trigger}
    end

    test "edits cooldown and fire-once, keeping the approved text and condition",
         %{professional: professional, patient: patient, trigger: trigger} do
      assert {:ok, updated} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "cooldown_hours" => "6",
                 "fire_once" => "true"
               })

      assert updated.cooldown_hours == 6
      assert updated.fire_once == true
      assert updated.decrypted_condition == @condition
      assert updated.decrypted_approved_text == @approved

      stored = Repo.get!(Trigger, trigger.id)
      assert %Trigger{cooldown_hours: 6, fire_once: true, cooldown_reset_at: nil} = stored
      assert stored.approved_text == trigger.approved_text
      assert stored.condition == trigger.condition
      assert [%AuditLog{details: %{}}] = audits(trigger.id, "trigger_updated")
    end

    test "editing the condition re-encrypts it, keeps approved text and resets the cooldown",
         %{professional: professional, patient: patient, trigger: trigger} do
      assert {:ok, updated} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "condition" => "  Menciona problemas de sueño  "
               })

      assert updated.decrypted_condition == "Menciona problemas de sueño"

      stored = Repo.get!(Trigger, trigger.id)
      assert stored.condition != trigger.condition
      assert stored.approved_text == trigger.approved_text
      assert stored.status == "active"
      assert %DateTime{} = stored.cooldown_reset_at
      assert [%AuditLog{details: details}] = audits(trigger.id, "trigger_updated")
      assert details == %{}

      assert {:ok, [listed]} = Triggers.list_triggers(professional, patient.id)
      assert listed.decrypted_condition == "Menciona problemas de sueño"
    end

    test "after a condition edit the trigger can fire immediately and history is kept",
         %{professional: professional, patient: patient, trigger: trigger} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      fired_at = DateTime.add(now, -3600, :second)

      assert {:ok, %TriggerFiring{}} =
               Triggers.fire_reactive_trigger(trigger.id, inbound_message(patient).id, fired_at)

      # Inside the cooldown: not eligible, not fireable.
      assert {:ok, []} = Triggers.eligible_reactive_triggers(patient, now)

      assert {:ok, :skipped} =
               Triggers.fire_reactive_trigger(trigger.id, inbound_message(patient).id, now)

      assert {:ok, _} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "condition" => "Menciona problemas de sueño"
               })

      assert {:ok, [%Trigger{id: id}]} = Triggers.eligible_reactive_triggers(patient, now)
      assert id == trigger.id

      later = DateTime.add(now, 5, :second)

      assert {:ok, %TriggerFiring{}} =
               Triggers.fire_reactive_trigger(trigger.id, inbound_message(patient).id, later)

      assert Repo.aggregate(TriggerFiring, :count) == 2

      # The new firing starts a fresh cooldown.
      assert {:ok, []} = Triggers.eligible_reactive_triggers(patient, later)
    end

    test "editing only the cooldown does not reset it",
         %{professional: professional, patient: patient, trigger: trigger} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, %TriggerFiring{}} =
        Triggers.fire_reactive_trigger(
          trigger.id,
          inbound_message(patient).id,
          DateTime.add(now, -3600, :second)
        )

      assert {:ok, _} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "cooldown_hours" => "12"
               })

      assert %Trigger{cooldown_reset_at: nil} = Repo.get!(Trigger, trigger.id)
      assert {:ok, []} = Triggers.eligible_reactive_triggers(patient, now)
    end

    test "an unchanged edit writes no audit and no row change",
         %{professional: professional, patient: patient, trigger: trigger} do
      before = Repo.get!(Trigger, trigger.id)

      assert {:ok, updated} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "condition" => @condition,
                 "cooldown_hours" => "24",
                 "fire_once" => "false"
               })

      assert updated.decrypted_condition == @condition
      assert Repo.get!(Trigger, trigger.id) == before
      assert audits(trigger.id, "trigger_updated") == []
    end

    test "rejects an empty condition and a non-positive cooldown without writing",
         %{professional: professional, patient: patient, trigger: trigger} do
      before = Repo.get!(Trigger, trigger.id)

      assert {:error, :empty_condition} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "condition" => "   "
               })

      assert {:error, %Ecto.Changeset{}} =
               Triggers.update_reactive_trigger(professional, patient.id, trigger.id, %{
                 "cooldown_hours" => "0"
               })

      assert Repo.get!(Trigger, trigger.id) == before
      assert audits(trigger.id, "trigger_updated") == []
    end

    test "rejects a trigger that is not reactive",
         %{professional: professional, patient: patient} do
      active = active_trigger(professional, patient)
      before = Repo.get!(Trigger, active.id)

      assert {:error, :not_reactive} =
               Triggers.update_reactive_trigger(professional, patient.id, active.id, %{
                 "fire_once" => "true"
               })

      assert Repo.get!(Trigger, active.id) == before
      assert audits(active.id, "trigger_updated") == []
    end

    test "is owner-scoped and reports unknown triggers",
         %{patient: patient, trigger: trigger, professional: professional} do
      %{professional: other} = fixture_professional_and_patient()
      before = Repo.get!(Trigger, trigger.id)

      assert {:error, :unauthorized} =
               Triggers.update_reactive_trigger(other, patient.id, trigger.id, %{
                 "fire_once" => "true"
               })

      assert {:error, :unauthorized} =
               Triggers.update_reactive_trigger(professional, "not-a-uuid", trigger.id, %{})

      assert {:error, :not_found} =
               Triggers.update_reactive_trigger(
                 professional,
                 patient.id,
                 Ecto.UUID.generate(),
                 %{"fire_once" => "true"}
               )

      assert Repo.get!(Trigger, trigger.id) == before
      assert audits(trigger.id, "trigger_updated") == []
    end
  end

  describe "active reactive trigger limit (S4, S5)" do
    setup do
      previous = Application.get_env(:alethea, :max_active_reactive_triggers)
      Application.put_env(:alethea, :max_active_reactive_triggers, 2)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:alethea, :max_active_reactive_triggers),
          else: Application.put_env(:alethea, :max_active_reactive_triggers, previous)
      end)
    end

    test "the limit defaults to 20 and is configurable", %{} do
      assert Triggers.max_active_reactive_triggers() == 2

      Application.delete_env(:alethea, :max_active_reactive_triggers)
      assert Triggers.max_active_reactive_triggers() == 20

      Application.put_env(:alethea, :max_active_reactive_triggers, 20)
      assert Triggers.max_active_reactive_triggers() == 20
      assert Application.get_env(:alethea, :max_active_reactive_triggers) == 20
    end

    test "the next reactive trigger past the limit is rejected and nothing is written",
         %{professional: professional, patient: patient} do
      {:ok, _} = create_reactive(professional, patient)
      {:ok, _} = create_reactive(professional, patient)
      triggers_before = Repo.aggregate(Trigger, :count)
      audits_before = trigger_audit_count()

      assert {:error, :reactive_limit_reached} = create_reactive(professional, patient)

      assert Repo.aggregate(Trigger, :count) == triggers_before
      assert trigger_audit_count() == audits_before
    end

    test "only active reactive triggers count and the limit is per patient",
         %{professional: professional, patient: patient} do
      {:ok, first} = create_reactive(professional, patient)
      {:ok, _} = create_reactive(professional, patient)
      _scheduled = active_trigger(professional, patient)
      _scheduled2 = active_trigger(professional, patient)
      _scheduled3 = active_trigger(professional, patient)

      assert {:error, :reactive_limit_reached} = create_reactive(professional, patient)

      # Deactivating one frees a slot.
      assert {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, first.id)
      assert {:ok, %Trigger{}} = create_reactive(professional, patient)

      # Another patient of the same professional has their own budget.
      %{patient: other_patient} = fixture_patient_for(professional)
      assert {:ok, _} = create_reactive(professional, other_patient)
    end

    test "activating a reactive trigger past the limit is rejected and leaves it inactive",
         %{professional: professional, patient: patient} do
      {:ok, a} = create_reactive(professional, patient)
      {:ok, _} = create_reactive(professional, patient)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, a.id)
      {:ok, _} = create_reactive(professional, patient)

      audits_before = trigger_audit_count()

      assert {:error, :reactive_limit_reached} =
               Triggers.activate_trigger(professional, patient.id, a.id)

      assert %Trigger{status: "inactive"} = Repo.get!(Trigger, a.id)
      assert trigger_audit_count() == audits_before
      assert audits(a.id, "trigger_activated") == []
    end

    test "resuming a paused reactive trigger past the limit is rejected and leaves it paused",
         %{professional: professional, patient: patient} do
      {:ok, a} = create_reactive(professional, patient)
      {:ok, _} = create_reactive(professional, patient)

      a |> Ecto.Changeset.change(status: "paused_by_crisis") |> Repo.update!()
      {:ok, _} = create_reactive(professional, patient)

      audits_before = trigger_audit_count()

      assert {:error, :reactive_limit_reached} =
               Triggers.resume_trigger(professional, patient.id, a.id)

      assert %Trigger{status: "paused_by_crisis"} = Repo.get!(Trigger, a.id)
      assert trigger_audit_count() == audits_before
    end

    test "activating or resuming below the limit still works",
         %{professional: professional, patient: patient} do
      {:ok, a} = create_reactive(professional, patient)
      {:ok, b} = create_reactive(professional, patient)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, a.id)

      assert {:ok, %Trigger{status: "active"}} =
               Triggers.activate_trigger(professional, patient.id, a.id)

      b |> Ecto.Changeset.change(status: "paused_by_crisis") |> Repo.update!()
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, a.id)

      assert {:ok, %Trigger{status: "active"}} =
               Triggers.resume_trigger(professional, patient.id, b.id)

      assert [_] = audits(a.id, "trigger_activated")
      assert [_] = audits(b.id, "trigger_resumed")
    end

    test "scheduled triggers are not limited and keep activating/resuming",
         %{professional: professional, patient: patient} do
      {:ok, _} = create_reactive(professional, patient)
      {:ok, _} = create_reactive(professional, patient)

      scheduled = for _ <- 1..3, do: active_trigger(professional, patient)
      assert Enum.all?(scheduled, &(&1.status == "active"))

      first = hd(scheduled)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, first.id)

      assert {:ok, %Trigger{status: "active", kind: "active"}} =
               Triggers.activate_trigger(professional, patient.id, first.id)
    end
  end

  defp fixture_patient_for(professional) do
    {:ok, kek} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{
          "alias" => "Otro #{System.unique_integer([:positive])}",
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    %{patient: patient}
  end

  # Trigger mutation audits only: reading the patient DEK writes its own,
  # unrelated access-audit entry before any limit check runs.
  defp trigger_audit_count do
    Repo.aggregate(from(a in AuditLog, where: a.resource_type == "trigger"), :count)
  end

  defp active_trigger(professional, patient) do
    {:ok, trigger} =
      Triggers.create_and_approve_trigger(professional, patient.id, %{
        instruction: "Recordar hidratación",
        approved_text: "Hola! Recuerda beber agua.",
        date: Date.utc_today() |> Date.add(2),
        time: ~T[10:00:00]
      })

    trigger
  end

  defp attrs(extra) do
    Map.merge(
      %{
        "condition" => @condition,
        "instruction" => @instruction,
        "draft_message" => @approved,
        "approved_text" => @approved
      },
      extra
    )
  end

  defp create_reactive(professional, patient, extra \\ %{}),
    do: Triggers.create_and_approve_reactive_trigger(professional, patient.id, attrs(extra))

  defp audits(trigger_id, action) do
    Repo.all(from a in AuditLog, where: a.resource_id == ^trigger_id and a.action == ^action)
  end

  defp inbound_message(patient) do
    {:ok, message} =
      Clinical.save_message(patient, "Hoy discutí con mi madre", nil, "inbound", "spontaneous")

    message
  end
end
