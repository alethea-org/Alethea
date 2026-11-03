defmodule Alethea.Jobs.TelegramMessageWorkerCrisisTriggersTest do
  @moduledoc """
  Tests that crisis inbound messages pause all active triggers of the patient (Issue #443).
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox

  alias Alethea.Accounts.AuditLog
  alias Alethea.Jobs.TelegramMessageWorker
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger
  alias AletheaJobs.ActiveTriggerWorker

  import Alethea.FoundationTestHelper

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @crisis_text "me voy a quitar la vida"

  setup :verify_on_exit!

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)
    Repo.delete_all(AuditLog)

    %{legacy_pro: legacy_pro, legacy_pat: legacy_pat} = bind_patient()
    %{professional: legacy_pro, patient: legacy_pat}
  end

  describe "perform/1 — crisis inbound pauses active triggers (Issue #443)" do
    test "pauses all active triggers of the patient on crisis, deletes scheduled jobs, and audits",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, trigger1} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar respiración",
          approved_text: "Hola, recuerda respirar.",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, trigger2} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar registro",
          approved_text: "Hola, recuerda registrar.",
          schedule_type: "daily",
          time: ~T[11:00:00]
        })

      {:ok, trigger3} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar agua",
          approved_text: "Hola, recuerda beber agua.",
          date: future_date,
          time: ~T[12:00:00]
        })

      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger3.id)

      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger1.id})
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger2.id})

      # Inbound crisis arrives
      assert :ok = perform_crisis_inbound()

      # Active triggers must be paused_by_crisis
      assert Repo.get!(Trigger, trigger1.id).status == "paused_by_crisis"
      assert Repo.get!(Trigger, trigger2.id).status == "paused_by_crisis"

      # Inactive trigger remains inactive
      assert Repo.get!(Trigger, trigger3.id).status == "inactive"

      # Oban jobs for paused triggers must be deleted
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger1.id})
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger2.id})

      # Audited
      assert Repo.get_by(AuditLog,
               resource_id: trigger1.id,
               action: "trigger_paused_by_crisis",
               professional_id: professional.id
             )

      assert Repo.get_by(AuditLog,
               resource_id: trigger2.id,
               action: "trigger_paused_by_crisis",
               professional_id: professional.id
             )
    end

    test "pauses triggers even on replay when reply already exists (TR-02)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      # First inbound message arrives
      assert :ok = perform_crisis_inbound()

      # Now patient creates an active trigger after the initial reply row existed
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar respiración",
          approved_text: "Hola, recuerda respirar.",
          date: future_date,
          time: ~T[10:00:00]
        })

      assert Repo.get!(Trigger, trigger.id).status == "active"

      # Re-execute crisis inbound (hits existing reply branch / collision)
      assert :ok = perform_crisis_inbound()

      # Trigger must be moved to paused_by_crisis
      assert Repo.get!(Trigger, trigger.id).status == "paused_by_crisis"
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})
    end
  end

  defp perform_crisis_inbound do
    TelegramMessageWorker.perform(%Oban.Job{
      args: %{
        "telegram_update_id" => 91,
        "message" => %{
          "message_id" => 901,
          "date" => 1_700_000_000,
          "chat" => %{"id" => @chat_id, "type" => "private"},
          "text" => @crisis_text
        }
      }
    })
  end

  defp bind_patient do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    legacy_pro =
      legacy_pro
      |> Ecto.Changeset.change(%{crisis_message: "Texto de crisis de prueba"})
      |> Repo.update!()

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_pro)

    {:ok, legacy_pat} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_pro.id},
        kek
      )

    foundation_pat
    |> Ecto.Changeset.change(%{
      telegram_chat_id_hash: @chat_id_hash,
      legacy_patient_id: legacy_pat.id
    })
    |> Repo.update!()

    %{legacy_pro: legacy_pro, legacy_pat: legacy_pat}
  end

  defp unique_int, do: System.unique_integer([:positive])
end
