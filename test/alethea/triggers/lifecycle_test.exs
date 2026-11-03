defmodule Alethea.Triggers.LifecycleTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger
  alias AletheaJobs.ActiveTriggerWorker

  setup do
    Repo.delete_all(Oban.Job)
    Repo.delete_all(AuditLog)
    fixture_professional_and_patient()
  end

  describe "deactivate_trigger/3 (S1, S3, S5)" do
    test "deactivates active trigger, updates status to inactive, audits action, and removes scheduled Oban job",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar hidratación",
          approved_text: "Hola! Recuerda beber agua.",
          date: future_date,
          time: ~T[10:00:00]
        })

      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      assert {:ok, deactivated} =
               Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      assert deactivated.id == trigger.id
      assert deactivated.status == "inactive"

      # Database record reflects inactive status
      assert Repo.get!(Trigger, trigger.id).status == "inactive"

      # Scheduled job removed from queue
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Content-free audit log created
      audit =
        Repo.get_by(AuditLog,
          resource_id: trigger.id,
          action: "trigger_deactivated",
          professional_id: professional.id
        )

      assert audit != nil
      assert audit.details == %{} or audit.details == nil
    end

    test "forbids non-owning professional from deactivating trigger (S5)" do
      other = fixture_professional_and_patient()
      owner = fixture_professional_and_patient()

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(owner.professional, owner.patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.utc_today() |> Date.add(1),
          time: ~T[10:00:00]
        })

      assert {:error, :unauthorized} =
               Triggers.deactivate_trigger(other.professional, owner.patient.id, trigger.id)

      assert Repo.get!(Trigger, trigger.id).status == "active"
    end
  end

  describe "activate_trigger/3 (S1, S3, S5, S6)" do
    test "expired once trigger activation returns actionable error and never fires immediately (S6)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar sesión",
          approved_text: "Hola! Recuerda tu sesión.",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, deactivated} =
        Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      # Make scheduled_at past
      past_dt = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      deactivated
      |> Ecto.Changeset.change(%{scheduled_at: past_dt})
      |> Repo.update!()

      assert {:error, {:expired_schedule, message}} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)

      assert message =~ "venció" or message =~ "pasado" or message =~ "futuro"

      # Status remains inactive and no job scheduled
      assert Repo.get!(Trigger, trigger.id).status == "inactive"
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})
    end

    test "resuming recurring daily trigger recomputes future occurrence in patient timezone without catch-up (S1, S6)",
         %{professional: professional, patient: patient} do
      time = ~T[16:00:00]
      end_date = Date.utc_today() |> Date.add(10)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          schedule_type: "daily",
          time: time,
          end_date: end_date,
          instruction: "Recordar respiración",
          approved_text: "Hola! Recuerda respirar."
        })

      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Reactivate trigger
      assert {:ok, activated} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)

      assert activated.status == "active"
      assert DateTime.compare(activated.scheduled_at, DateTime.utc_now()) == :gt

      # New ActiveTriggerWorker job is scheduled for the recomputed future occurrence
      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id}
      )

      # Content-free audit log
      audit =
        Repo.get_by(AuditLog,
          resource_id: trigger.id,
          action: "trigger_activated",
          professional_id: professional.id
        )

      assert audit != nil
      assert audit.details == %{} or audit.details == nil
    end

    test "recurring trigger whose end_date has passed cannot be activated (S6)",
         %{professional: professional, patient: patient} do
      time = ~T[10:00:00]
      end_date = Date.utc_today() |> Date.add(5)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          schedule_type: "daily",
          time: time,
          end_date: end_date,
          instruction: "Recordar tarea",
          approved_text: "Hola! Recuerda la tarea."
        })

      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      # Set end_date to yesterday
      past_date = Date.utc_today() |> Date.add(-1)

      trigger
      |> Ecto.Changeset.change(%{end_date: past_date})
      |> Repo.update!()

      assert {:error, {:end_date_passed, _}} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)

      assert Repo.get!(Trigger, trigger.id).status == "inactive"
    end

    test "cannot activate unapproved trigger without approval",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Original",
          approved_text: "Original texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      # Edit instruction to make it unapproved
      {:ok, updated} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instruccion"
        )

      assert is_nil(updated.decrypted_approved_text)

      # Attempting to activate an unapproved trigger returns error
      assert {:error, :unapproved} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)
    end
  end

  describe "update_trigger_instruction/4 (S2, S3, S5)" do
    test "editing instruction clears approved_text and stale draft persistently, increments revision, and audits (S2, S3)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(3)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion inicial",
          approved_text: "Texto inicial aprobado",
          draft_message: "Texto inicial borrador",
          date: future_date,
          time: ~T[11:00:00]
        })

      assert trigger.approval_revision == 1

      new_instruction = "Instruccion modificada por el terapeuta"

      assert {:ok, updated} =
               Triggers.update_trigger_instruction(
                 professional,
                 patient.id,
                 trigger.id,
                 new_instruction
               )

      assert updated.id == trigger.id
      assert updated.decrypted_instruction == new_instruction
      assert is_nil(updated.decrypted_approved_text)
      assert is_nil(updated.decrypted_draft_message)
      assert updated.approval_revision > trigger.approval_revision

      # Database record has null approved_text and draft_message
      db_trigger = Repo.get!(Trigger, trigger.id)
      assert is_nil(db_trigger.approved_text)
      assert is_nil(db_trigger.draft_message)
      assert db_trigger.approval_revision == updated.approval_revision

      # Encrypted instruction updated
      {:ok, dek} = Clinical.patient_dek(patient, "test_check")
      assert {:ok, ^new_instruction} = PatientVault.decrypt(db_trigger.instruction, dek)

      # Audit log written
      audit =
        Repo.get_by(AuditLog,
          resource_id: trigger.id,
          action: "trigger_updated",
          professional_id: professional.id
        )

      assert audit != nil
      assert audit.details == %{} or audit.details == nil
    end

    test "exact unchanged instruction preserves approved text and does not require reapproval",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)
      instruction = "Instruccion intacta"
      approved_text = "Texto intacto aprobado"

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: instruction,
          approved_text: approved_text,
          date: future_date,
          time: ~T[12:00:00]
        })

      # Call update with exact same instruction (with leading/trailing whitespace to test trim)
      assert {:ok, updated} =
               Triggers.update_trigger_instruction(
                 professional,
                 patient.id,
                 trigger.id,
                 "  #{instruction}  "
               )

      assert updated.decrypted_instruction == instruction
      assert updated.decrypted_approved_text == approved_text
      assert updated.approval_revision == trigger.approval_revision

      db_trigger = Repo.get!(Trigger, trigger.id)
      refute is_nil(db_trigger.approved_text)
    end

    test "rejects empty instruction", %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion inicial",
          approved_text: "Texto",
          date: future_date,
          time: ~T[12:00:00]
        })

      assert {:error, :empty_instruction} =
               Triggers.update_trigger_instruction(professional, patient.id, trigger.id, "   ")
    end
  end

  describe "reapprove_trigger/4 (S2, S3, S5)" do
    test "reapproves unapproved trigger, binds to expected revision, re-enqueues Oban job and audits",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(3)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion previa",
          approved_text: "Texto previo",
          date: future_date,
          time: ~T[14:00:00]
        })

      {:ok, unapproved} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instruccion"
        )

      current_rev = unapproved.approval_revision
      new_approved = "Nuevo mensaje redactado y aprobado por el profesional"

      assert {:ok, reapproved} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: new_approved,
                 expected_revision: current_rev
               })

      assert reapproved.decrypted_approved_text == new_approved
      refute is_nil(Repo.get!(Trigger, trigger.id).approved_text)

      # Oban job scheduled
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Audit logs: initial create_and_approve plus reapproval
      approval_audits =
        Repo.all(
          from(a in AuditLog,
            where:
              a.resource_id == ^trigger.id and
                a.action == "trigger_approved" and
                a.professional_id == ^professional.id
          )
        )

      assert length(approval_audits) == 2
    end

    test "rejects approval if expected revision is stale (concurrent edit safety)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(3)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion previa",
          approved_text: "Texto previo",
          date: future_date,
          time: ~T[14:00:00]
        })

      {:ok, _unapproved} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instruccion"
        )

      # Attempt to reapprove with old revision (e.g. from earlier session snapshot)
      stale_rev = trigger.approval_revision

      assert {:error, :stale_revision} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: "Texto para snapshot viejo",
                 expected_revision: stale_rev
               })
    end

    test "rejects approval when expected_revision is omitted, nil, or non-positive integer without mutating state",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(3)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion previa",
          approved_text: "Texto previo",
          date: future_date,
          time: ~T[14:00:00]
        })

      {:ok, _unapproved} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instruccion"
        )

      Repo.delete_all(Oban.Job)
      audits_before = Repo.aggregate(AuditLog, :count, :id)

      # 1. Omitted expected_revision
      assert {:error, :missing_expected_revision} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: "Texto sin revision esperada"
               })

      # 2. Nil expected_revision
      assert {:error, :missing_expected_revision} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: "Texto sin revision esperada",
                 expected_revision: nil
               })

      # 3. Non-positive integer (0 or negative)
      assert {:error, :missing_expected_revision} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: "Texto con revision 0",
                 expected_revision: 0
               })

      assert {:error, :missing_expected_revision} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: "Texto con revision negativa",
                 expected_revision: -1
               })

      # 4. String or non-integer
      assert {:error, :missing_expected_revision} =
               Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
                 approved_text: "Texto con revision string",
                 expected_revision: "dos"
               })

      # Assert NO mutations: trigger remains unapproved
      db_trigger = Repo.get!(Trigger, trigger.id)
      assert is_nil(db_trigger.approved_text)

      # Assert NO new audit logs
      assert Repo.aggregate(AuditLog, :count, :id) == audits_before

      # Assert NO new Oban jobs scheduled
      refute_enqueued(worker: ActiveTriggerWorker)
    end
  end

  describe "list_triggers/2 (S1, S2, S5)" do
    test "lists all triggers for patient including active, inactive and unapproved",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, t1} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Trigger 1 activo",
          approved_text: "Texto 1",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, t2} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Trigger 2 inactivo",
          approved_text: "Texto 2",
          date: future_date,
          time: ~T[11:00:00]
        })

      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, t2.id)

      {:ok, t3} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Trigger 3 sin aprobar",
          approved_text: "Texto 3",
          date: future_date,
          time: ~T[12:00:00]
        })

      {:ok, _} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          t3.id,
          "Trigger 3 nueva instruccion"
        )

      assert {:ok, all} = Triggers.list_triggers(professional, patient.id)
      ids = Enum.map(all, & &1.id)
      assert t1.id in ids
      assert t2.id in ids
      assert t3.id in ids

      # list_active_triggers preserves existing semantics (only active & approved)
      assert {:ok, active_only} = Triggers.list_active_triggers(professional, patient.id)
      active_ids = Enum.map(active_only, & &1.id)
      assert t1.id in active_ids
      refute t2.id in active_ids
      refute t3.id in active_ids
    end
  end
end
