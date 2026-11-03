defmodule AletheaJobs.TriggerLifecycleTest do
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
    Repo.delete_all(Oban.Job)
    Repo.delete_all(AuditLog)
    fixture_professional_and_patient()
  end

  describe "ActiveTriggerWorker with inactive and unapproved triggers (S1, S2)" do
    test "inactive trigger never fires when worker runs at due time (S1)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar hidratación",
          approved_text: "Hola! Recuerda beber agua hoy.",
          date: future_date,
          time: ~T[10:00:00]
        })

      # Deactivate trigger
      {:ok, _deactivated} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      # Simulate that trigger is due (past scheduled_at)
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger
      |> Ecto.Changeset.change(%{scheduled_at: due_at})
      |> Repo.update!()

      Repo.delete_all(Oban.Job)

      # Run worker
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Trigger status remains inactive
      assert Repo.get!(Trigger, trigger.id).status == "inactive"

      # No message, firing, outbound job or trigger_fired audit log created
      assert Repo.aggregate(Message, :count, :id) == 0
      assert Repo.aggregate(TriggerFiring, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)

      refute Repo.get_by(AuditLog,
               resource_id: trigger.id,
               action: "trigger_fired"
             )
    end

    test "unapproved trigger (approved_text is nil) never fires when worker runs at due time (S2)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar hidratación",
          approved_text: "Hola! Recuerda beber agua hoy.",
          date: future_date,
          time: ~T[10:00:00]
        })

      # Edit instruction to clear approved_text
      {:ok, _updated} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instruccion de hidratacion"
        )

      # Make trigger due
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger
      |> Ecto.Changeset.change(%{scheduled_at: due_at})
      |> Repo.update!()

      Repo.delete_all(Oban.Job)

      # Run worker
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # No message, firing, outbound job or trigger_fired audit log created
      assert Repo.aggregate(Message, :count, :id) == 0
      assert Repo.aggregate(TriggerFiring, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)
    end
  end
end
