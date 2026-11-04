defmodule Alethea.Triggers.ReactiveTest do
  @moduledoc """
  Context-level behaviour of reactive triggers (#448): creation and
  approval, eligibility for matching (status, approval, cooldown), firing
  records, summary counts, and the crisis pause/resume lifecycle they share
  with active triggers.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}
  alias AletheaJobs.ActiveTriggerWorker

  @condition "Habla de una discusión con su madre"
  @instruction "Retomar el ejercicio de comunicación asertiva"
  @approved "¿Te sirvió practicar lo que conversamos sobre comunicarte con calma?"

  setup do
    Repo.delete_all(Oban.Job)
    fixture_professional_and_patient()
  end

  describe "create_and_approve_reactive_trigger/3" do
    test "stores an encrypted, approved reactive trigger with a 24h default cooldown and no job",
         %{professional: professional, patient: patient} do
      assert {:ok, trigger} =
               Triggers.create_and_approve_reactive_trigger(professional, patient.id, attrs())

      assert trigger.kind == "reactive"
      assert trigger.status == "active"
      assert trigger.cooldown_hours == 24
      assert is_nil(trigger.scheduled_at)
      assert is_nil(trigger.schedule_type)
      assert trigger.decrypted_condition == @condition
      assert trigger.decrypted_instruction == @instruction
      assert trigger.decrypted_approved_text == @approved

      db = Repo.get!(Trigger, trigger.id)
      refute db.condition =~ @condition
      refute db.approved_text =~ @approved

      {:ok, dek} = Clinical.patient_dek(patient, "test_check")
      assert {:ok, @condition} = PatientVault.decrypt(db.condition, dek)
      assert {:ok, @approved} = PatientVault.decrypt(db.approved_text, dek)

      refute_enqueued(worker: ActiveTriggerWorker)

      actions =
        Repo.all(
          from a in AuditLog,
            where: a.resource_id == ^trigger.id,
            select: {a.action, a.details}
        )

      assert {"trigger_created", %{}} in actions
      assert {"trigger_approved", %{}} in actions
    end

    test "accepts an explicit cooldown", %{professional: professional, patient: patient} do
      assert {:ok, %Trigger{cooldown_hours: 6}} =
               Triggers.create_and_approve_reactive_trigger(
                 professional,
                 patient.id,
                 Map.put(attrs(), "cooldown_hours", 6)
               )
    end

    test "rejects an empty condition, instruction or approved text",
         %{professional: professional, patient: patient} do
      assert {:error, :empty_condition} =
               Triggers.create_and_approve_reactive_trigger(
                 professional,
                 patient.id,
                 Map.put(attrs(), "condition", "  ")
               )

      assert {:error, :empty_instruction} =
               Triggers.create_and_approve_reactive_trigger(
                 professional,
                 patient.id,
                 Map.put(attrs(), "instruction", "")
               )

      assert {:error, :empty_approved_text} =
               Triggers.create_and_approve_reactive_trigger(
                 professional,
                 patient.id,
                 Map.put(attrs(), "approved_text", "")
               )

      assert Repo.aggregate(Trigger, :count) == 0
    end

    test "forbids a professional who does not own the patient", %{patient: patient} do
      other = fixture_professional_and_patient()

      assert {:error, :unauthorized} =
               Triggers.create_and_approve_reactive_trigger(
                 other.professional,
                 patient.id,
                 attrs()
               )
    end
  end

  describe "eligible_reactive_triggers/2" do
    test "returns active, approved reactive triggers with their decrypted condition",
         %{professional: professional, patient: patient} do
      {:ok, reactive} = create_reactive(professional, patient)
      {:ok, _scheduled} = create_scheduled(professional, patient)

      assert {:ok, [eligible]} = Triggers.eligible_reactive_triggers(patient)
      assert eligible.id == reactive.id
      assert eligible.decrypted_condition == @condition
      assert eligible.decrypted_approved_text == @approved
    end

    test "excludes inactive, crisis-paused and unapproved reactive triggers",
         %{professional: professional, patient: patient} do
      {:ok, inactive} = create_reactive(professional, patient)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, inactive.id)

      {:ok, unapproved} = create_reactive(professional, patient)

      {:ok, _} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          unapproved.id,
          "Otra instrucción"
        )

      assert {:ok, []} = Triggers.eligible_reactive_triggers(patient)

      {:ok, _paused} = create_reactive(professional, patient)
      {:ok, _paused_count} = Triggers.pause_active_triggers_for_crisis(patient.id)

      assert {:ok, []} = Triggers.eligible_reactive_triggers(patient)
    end

    test "excludes a trigger fired within its cooldown and re-admits it after",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      message = inbound_message(patient)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _firing} =
        Triggers.record_reactive_firing(trigger.id, message.id, DateTime.add(now, -23, :hour))

      assert {:ok, []} = Triggers.eligible_reactive_triggers(patient, now)

      assert {:ok, [%Trigger{id: id}]} =
               Triggers.eligible_reactive_triggers(patient, DateTime.add(now, 2, :hour))

      assert id == trigger.id
    end
  end

  describe "record_reactive_firing/3" do
    test "links the firing to the matched patient message without altering it",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      message = inbound_message(patient)
      fired_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, %TriggerFiring{} = firing} =
               Triggers.record_reactive_firing(trigger.id, message.id, fired_at)

      assert firing.message_id == message.id
      assert firing.fired_at == fired_at
      assert firing.scheduled_at == fired_at
      assert Repo.get!(Alethea.Clinical.Message, message.id).behavior_type == "spontaneous"

      assert {:error, %Ecto.Changeset{}} =
               Triggers.record_reactive_firing(
                 trigger.id,
                 message.id,
                 DateTime.add(fired_at, 1, :hour)
               )
    end
  end

  describe "fire_reactive_trigger/3" do
    test "records the firing when the trigger is still eligible",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      message = inbound_message(patient)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, %TriggerFiring{} = firing} =
               Triggers.fire_reactive_trigger(trigger.id, message.id, now)

      assert firing.trigger_id == trigger.id
      assert firing.message_id == message.id
    end

    test "skips the firing when another firing landed within the cooldown after the match",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      earlier = inbound_message(patient)
      message = inbound_message(patient)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _concurrent} =
        Triggers.record_reactive_firing(trigger.id, earlier.id, DateTime.add(now, -1, :minute))

      assert {:ok, :skipped} = Triggers.fire_reactive_trigger(trigger.id, message.id, now)
      assert Repo.aggregate(TriggerFiring, :count) == 1

      assert [%AuditLog{resource_type: "trigger", details: details} = audit] =
               Repo.all(from a in AuditLog, where: a.action == "trigger_firing_skipped_cooldown")

      assert audit.resource_id == trigger.id
      assert audit.professional_id == professional.id
      assert details == %{}
    end

    test "skips the firing when the trigger was paused or deactivated after the match",
         %{professional: professional, patient: patient} do
      {:ok, paused} = create_reactive(professional, patient)
      {:ok, _} = Triggers.pause_active_triggers_for_crisis(patient.id)
      message = inbound_message(patient)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, :skipped} = Triggers.fire_reactive_trigger(paused.id, message.id, now)
      assert Repo.aggregate(TriggerFiring, :count) == 0

      refute Repo.exists?(
               from a in AuditLog, where: a.action == "trigger_firing_skipped_cooldown"
             )
    end
  end

  describe "privacy of the condition" do
    test "the condition column holds ciphertext, never the plaintext",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)

      %{rows: [[raw]]} =
        Repo.query!("SELECT condition FROM triggers WHERE id = $1", [
          Ecto.UUID.dump!(trigger.id)
        ])

      assert is_binary(raw)
      assert byte_size(raw) > 0
      refute raw =~ @condition
      refute raw == @condition
    end

    test "audit details and enqueued job args never carry the condition",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      {:ok, _} = Triggers.pause_active_triggers_for_crisis(patient.id)
      {:ok, _} = Triggers.resume_trigger(professional, patient.id, trigger.id)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      details =
        Repo.all(from a in AuditLog, where: a.resource_id == ^trigger.id, select: a.details)

      assert length(details) >= 4
      refute inspect(details, printable_limit: :infinity) =~ @condition

      args = Repo.all(from j in Oban.Job, select: j.args)
      refute inspect(args, printable_limit: :infinity) =~ @condition
    end
  end

  describe "reapprove_trigger/4 on a reactive trigger" do
    test "updates the approved text without computing a schedule or enqueuing a job",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)

      assert {:ok, reapproved} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 "expected_revision" => trigger.approval_revision,
                 "approved_text" => "Texto reaprobado"
               })

      assert reapproved.status == "active"
      assert reapproved.kind == "reactive"
      assert reapproved.decrypted_approved_text == "Texto reaprobado"
      assert is_nil(reapproved.scheduled_at)
      assert is_nil(reapproved.schedule_type)
      refute_enqueued(worker: ActiveTriggerWorker)
    end

    test "a crisis-paused reactive trigger can be reapproved and stays paused without a job",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)

      assert {:ok, reapproved} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 "expected_revision" => trigger.approval_revision,
                 "approved_text" => "Texto reaprobado"
               })

      assert reapproved.status == "paused_by_crisis"
      refute_enqueued(worker: ActiveTriggerWorker)

      assert {:ok, %Trigger{status: "active"}} =
               Triggers.resume_trigger(professional, patient.id, trigger.id)

      refute_enqueued(worker: ActiveTriggerWorker)
    end
  end

  describe "get_trigger_summary/2" do
    test "counts reactive triggers under the reactive kind",
         %{professional: professional, patient: patient} do
      {:ok, _} = create_scheduled(professional, patient)
      {:ok, _} = create_reactive(professional, patient)
      {:ok, inactive} = create_reactive(professional, patient)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, inactive.id)

      assert {:ok, summary} = Triggers.get_trigger_summary(professional, patient.id)

      assert summary.total == 3
      assert summary.by_kind.active.total == 1
      assert summary.by_kind.active.active == 1
      assert summary.by_kind.reactive.total == 2
      assert summary.by_kind.reactive.active == 1
      assert summary.by_kind.reactive.inactive == 1
      assert summary.reactive_kind == summary.by_kind.reactive
      assert summary.by_status.active == 2
      assert summary.by_status.inactive == 1
    end
  end

  describe "crisis lifecycle shared with active triggers" do
    test "a crisis pauses a reactive trigger and the professional can resume it",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)

      assert {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)
      assert Repo.get!(Trigger, trigger.id).status == "paused_by_crisis"

      assert {:ok, resumed} = Triggers.resume_trigger(professional, patient.id, trigger.id)
      assert resumed.status == "active"
      assert resumed.decrypted_condition == @condition
      refute_enqueued(worker: ActiveTriggerWorker)
    end

    test "a deactivated reactive trigger can be activated again",
         %{professional: professional, patient: patient} do
      {:ok, trigger} = create_reactive(professional, patient)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      assert {:ok, %Trigger{status: "active"}} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)

      refute_enqueued(worker: ActiveTriggerWorker)
    end
  end

  defp attrs do
    %{
      "condition" => @condition,
      "instruction" => @instruction,
      "draft_message" => @approved,
      "approved_text" => @approved
    }
  end

  defp create_reactive(professional, patient),
    do: Triggers.create_and_approve_reactive_trigger(professional, patient.id, attrs())

  defp create_scheduled(professional, patient) do
    Triggers.create_and_approve_trigger(professional, patient.id, %{
      instruction: "Recordar respiración",
      approved_text: "Hola, recuerda respirar.",
      date: Date.utc_today() |> Date.add(2),
      time: ~T[10:00:00]
    })
  end

  defp inbound_message(patient) do
    {:ok, message} =
      Clinical.save_message(patient, "Hoy discutí con mi madre", nil, "inbound", "spontaneous")

    message
  end
end
