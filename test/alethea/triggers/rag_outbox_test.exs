defmodule Alethea.Triggers.RagOutboxTest do
  @moduledoc """
  GitHub #452: every trigger mutation and firing enqueues a RAG context
  outbox job (`trigger_saved` / `trigger_firing_created`) through
  `Alethea.ClinicalRecord.Outbox.trigger_event/5`, the same queue the
  clinical-record projection uses.
  """
  use Alethea.DataCase, async: false

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}

  @worker "AletheaJobs.ClinicalRecordOutboxWorker"

  defp rag_jobs(event, patient_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^@worker,
        where: fragment("args->>'event'") == ^event,
        where: fragment("args->>'patient_id'") == ^patient_id,
        select: j.args
      )
    )
  end

  import Ecto.Query

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "trigger-rag-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Trigger Rag"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    %{professional: professional, patient: patient}
  end

  test "creating a reactive trigger enqueues trigger_saved", %{
    professional: professional,
    patient: patient
  } do
    {:ok, trigger} =
      Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
        "condition" => "si habla de su jefe",
        "instruction" => "recordarle la tecnica de respiracion",
        "approved_text" => "Prueba la tecnica de respiracion."
      })

    assert [%{"resource_id" => trigger_id, "resource_type" => "trigger"}] =
             rag_jobs("trigger_saved", patient.id)

    assert trigger_id == trigger.id

    assert [%{"patient_id" => patient_id, "professional_id" => professional_id}] =
             rag_jobs("trigger_saved", patient.id)

    assert patient_id == patient.id
    assert professional_id == professional.id
  end

  test "creating an active trigger enqueues trigger_saved", %{
    professional: professional,
    patient: patient
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, trigger} =
      Triggers.create_and_approve_trigger(professional, patient.id, %{
        instruction: "recordarle respirar antes de la reunion",
        approved_text: "Respira hondo antes de la reunion.",
        schedule_type: "once",
        date: DateTime.to_date(now) |> Date.add(1),
        time: ~T[10:00:00]
      })

    assert [%{"resource_id" => trigger_id}] = rag_jobs("trigger_saved", patient.id)
    assert trigger_id == trigger.id
  end

  test "recording a reactive firing enqueues trigger_firing_created", %{
    professional: professional,
    patient: patient
  } do
    {:ok, trigger} =
      Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
        "condition" => "si habla de su madre",
        "instruction" => "recordarle la sesion del martes",
        "approved_text" => "Recuerda lo que trabajamos el martes."
      })

    {:ok, message} =
      Clinical.save_message(patient, "Pelea con mi madre", nil, "inbound", "spontaneous")

    {:ok, firing} = Triggers.record_reactive_firing(trigger.id, message.id, DateTime.utc_now())

    assert [%{"resource_id" => firing_id, "resource_type" => "trigger_firing"}] =
             rag_jobs("trigger_firing_created", patient.id)

    assert firing_id == firing.id
  end

  test "delivery-failure pause re-enqueues trigger_saved (Jorge TR-001)", %{
    professional: professional,
    patient: patient
  } do
    {:ok, trigger} =
      Triggers.create_and_approve_trigger(professional, patient.id, %{
        instruction: "Instruccion",
        approved_text: "Texto",
        schedule_type: "daily",
        time: ~T[11:00:00],
        date: Date.add(Date.utc_today(), 1)
      })

    trigger
    |> Ecto.Changeset.change(consecutive_delivery_failures: 2)
    |> Repo.update!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message =
      %Clinical.Message{}
      |> Clinical.Message.changeset(%{
        patient_id: patient.id,
        direction: "outbound",
        behavior_type: "spontaneous",
        encrypted_content: trigger.approved_text,
        timestamp: now
      })
      |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
      |> Ecto.Changeset.put_change(:delivery_state, "failed")
      |> Repo.insert!()

    %TriggerFiring{}
    |> TriggerFiring.changeset(%{
      trigger_id: trigger.id,
      message_id: message.id,
      status: "fired",
      fired_at: now,
      scheduled_at: trigger.scheduled_at
    })
    |> Repo.insert!()

    assert :ok = Triggers.handle_delivery_failure(message.id)
    assert Repo.get!(Trigger, trigger.id).status == "paused_by_delivery_failures"

    # create + pause
    assert length(rag_jobs("trigger_saved", patient.id)) == 2
  end

  test "deactivating a trigger re-enqueues trigger_saved", %{
    professional: professional,
    patient: patient
  } do
    {:ok, trigger} =
      Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
        "condition" => "si habla de su jefe",
        "instruction" => "recordarle la analogia del monstruo",
        "approved_text" => "Recuerda la analogia del monstruo."
      })

    assert {:ok, _trigger} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)
    # create + deactivate
    assert length(rag_jobs("trigger_saved", patient.id)) == 2
  end
end
