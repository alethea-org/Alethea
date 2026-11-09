defmodule Alethea.Triggers.ArchiveTriggerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures
  import Ecto.Query

  alias Alethea.Accounts.AuditLog
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger
  alias AletheaJobs.ActiveTriggerWorker

  setup do
    Repo.delete_all(Oban.Job)
    Repo.delete_all(AuditLog)
    fixture_professional_and_patient()
  end

  describe "archive_trigger/3" do
    test "archives an active trigger: hidden from listings, jobs cancelled, audited",
         %{professional: professional, patient: patient} do
      trigger = active_trigger(professional, patient)
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      assert {:ok, archived} = Triggers.archive_trigger(professional, patient.id, trigger.id)

      assert archived.status == "inactive"
      assert %DateTime{} = archived.archived_at

      db = Repo.get!(Trigger, trigger.id)
      assert db.status == "inactive"
      assert %DateTime{} = db.archived_at

      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      assert {:ok, listed} = Triggers.list_triggers(professional, patient.id)
      refute Enum.any?(listed, &(&1.id == trigger.id))

      assert {:ok, active} = Triggers.list_active_triggers(professional, patient.id)
      refute Enum.any?(active, &(&1.id == trigger.id))

      assert {:ok, summary} = Triggers.get_trigger_summary(professional, patient.id)
      assert summary.total == 0

      assert Repo.get_by(AuditLog,
               resource_id: trigger.id,
               action: "trigger_archived",
               professional_id: professional.id
             )
    end

    test "archives an already fired trigger and keeps its fired status",
         %{professional: professional, patient: patient} do
      trigger = active_trigger(professional, patient)
      Repo.update_all(from(t in Trigger, where: t.id == ^trigger.id), set: [status: "fired"])

      assert {:ok, archived} = Triggers.archive_trigger(professional, patient.id, trigger.id)

      db = Repo.get!(Trigger, trigger.id)
      assert archived.status == "fired"
      assert db.status == "fired"
      assert %DateTime{} = db.archived_at

      assert {:ok, listed} = Triggers.list_triggers(professional, patient.id)
      refute Enum.any?(listed, &(&1.id == trigger.id))
    end

    test "archives a reactive trigger so it is no longer eligible to fire",
         %{professional: professional, patient: patient} do
      {:ok, trigger} =
        Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
          "condition" => "Habla de su padre",
          "instruction" => "Retomar la historia de la mosca",
          "draft_message" => "Texto reactivo",
          "approved_text" => "Texto reactivo"
        })

      assert {:ok, archived} = Triggers.archive_trigger(professional, patient.id, trigger.id)
      assert archived.status == "inactive"

      legacy_patient = Repo.get!(Alethea.Accounts.Patient, patient.id)
      assert {:ok, eligible} = Triggers.eligible_reactive_triggers(legacy_patient)
      refute Enum.any?(eligible, &(&1.id == trigger.id))

      assert {:ok, listed} = Triggers.list_triggers(professional, patient.id)
      refute Enum.any?(listed, &(&1.id == trigger.id))
    end

    test "archiving twice is idempotent and audits once",
         %{professional: professional, patient: patient} do
      trigger = active_trigger(professional, patient)

      assert {:ok, first} = Triggers.archive_trigger(professional, patient.id, trigger.id)
      assert {:ok, second} = Triggers.archive_trigger(professional, patient.id, trigger.id)
      assert first.archived_at == second.archived_at

      count =
        Repo.aggregate(
          from(a in AuditLog,
            where: a.resource_id == ^trigger.id and a.action == "trigger_archived"
          ),
          :count
        )

      assert count == 1
    end

    test "rejects another professional's trigger without changes",
         %{professional: professional, patient: patient} do
      trigger = active_trigger(professional, patient)
      %{professional: other} = fixture_professional_and_patient()

      assert {:error, :unauthorized} = Triggers.archive_trigger(other, patient.id, trigger.id)

      db = Repo.get!(Trigger, trigger.id)
      assert db.status == "active"
      assert is_nil(db.archived_at)
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})
    end

    test "returns not_found for an unknown trigger id",
         %{professional: professional, patient: patient} do
      assert {:error, :not_found} =
               Triggers.archive_trigger(professional, patient.id, Ecto.UUID.generate())
    end
  end

  describe "deactivate_trigger/3 (unchanged)" do
    test "still deactivates without archiving",
         %{professional: professional, patient: patient} do
      trigger = active_trigger(professional, patient)

      assert {:ok, deactivated} =
               Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      assert deactivated.status == "inactive"
      assert is_nil(Repo.get!(Trigger, trigger.id).archived_at)

      assert {:ok, listed} = Triggers.list_triggers(professional, patient.id)
      assert Enum.any?(listed, &(&1.id == trigger.id))
    end
  end

  defp active_trigger(professional, patient) do
    {:ok, trigger} =
      Triggers.create_and_approve_trigger(professional, patient.id, %{
        instruction: "Instruccion",
        approved_text: "Texto",
        date: Date.utc_today() |> Date.add(1),
        time: ~T[10:00:00]
      })

    trigger
  end
end
