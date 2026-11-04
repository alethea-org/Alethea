defmodule Alethea.TriggersTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures
  import Mox
  import Ecto.Query

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

  describe "create_and_approve_trigger/3" do
    test "schedules trigger at correct UTC instant, encrypts content, logs audit, and enqueues ActiveTriggerWorker",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)
      time = ~T[15:00:00]
      instruction = "Preguntar cómo se sintió con el ejercicio de respiración"
      approved_text = "Hola! ¿Cómo te sentiste hoy con el ejercicio de respiración?"

      assert {:ok, trigger} =
               Triggers.create_and_approve_trigger(professional, patient.id, %{
                 instruction: instruction,
                 approved_text: approved_text,
                 date: future_date,
                 time: time
               })

      assert trigger.status == "active"
      assert trigger.timezone == patient.timezone
      assert trigger.patient_id == patient.id
      assert trigger.professional_id == professional.id

      # Raw database record has encrypted binaries, not plain text
      db_trigger = Repo.get!(Trigger, trigger.id)
      assert is_binary(db_trigger.instruction)
      refute db_trigger.instruction =~ instruction
      assert is_binary(db_trigger.approved_text)
      refute db_trigger.approved_text =~ approved_text

      # Decrypts with patient DEK
      {:ok, dek} = Clinical.patient_dek(patient, "test_check")
      assert {:ok, ^instruction} = PatientVault.decrypt(db_trigger.instruction, dek)
      assert {:ok, ^approved_text} = PatientVault.decrypt(db_trigger.approved_text, dek)

      # Schedules exactly one ActiveTriggerWorker job with only IDs in args
      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id}
      )

      [job] =
        Repo.all(
          Ecto.Query.from(j in Oban.Job, where: j.worker == "AletheaJobs.ActiveTriggerWorker")
        )

      assert job.args == %{"trigger_id" => trigger.id}
      assert DateTime.compare(job.scheduled_at, trigger.scheduled_at) == :eq

      # Content-free audit logs in the same transaction for create and approve
      audit_actions =
        Repo.all(
          Ecto.Query.from(a in AuditLog,
            where: a.resource_id == ^trigger.id,
            select: {a.action, a.details}
          )
        )

      assert {"trigger_created", details1} =
               Enum.find(audit_actions, fn {act, _} -> act == "trigger_created" end)

      assert {"trigger_approved", details2} =
               Enum.find(audit_actions, fn {act, _} -> act == "trigger_approved" end)

      assert details1 == %{} or details1 == nil
      assert details2 == %{} or details2 == nil
    end

    test "rejects past schedule", %{professional: professional, patient: patient} do
      past_date = Date.utc_today() |> Date.add(-2)
      time = ~T[10:00:00]

      assert {:error, :past_schedule} =
               Triggers.create_and_approve_trigger(professional, patient.id, %{
                 instruction: "Instruccion",
                 approved_text: "Texto aprobado",
                 date: past_date,
                 time: time
               })

      refute_enqueued(worker: ActiveTriggerWorker)
    end

    test "creates daily trigger with optional end_date",
         %{professional: professional, patient: patient} do
      time = ~T[15:30:00]
      end_date = Date.utc_today() |> Date.add(10)
      instruction = "Instruccion diaria"
      approved_text = "Texto diario para paciente"

      assert {:ok, trigger} =
               Triggers.create_and_approve_trigger(professional, patient.id, %{
                 schedule_type: "daily",
                 time: time,
                 end_date: end_date,
                 instruction: instruction,
                 approved_text: approved_text
               })

      assert trigger.status == "active"
      assert trigger.schedule_type == "daily"
      assert trigger.time == time
      assert trigger.end_date == end_date
      assert trigger.scheduled_at != nil

      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id}
      )
    end

    test "creates weekly trigger with weekdays and optional end_date",
         %{professional: professional, patient: patient} do
      time = ~T[10:00:00]
      weekdays = [1, 3, 5]
      end_date = Date.utc_today() |> Date.add(30)
      instruction = "Instruccion semanal"
      approved_text = "Texto semanal para paciente"

      assert {:ok, trigger} =
               Triggers.create_and_approve_trigger(professional, patient.id, %{
                 schedule_type: "weekly",
                 time: time,
                 weekdays: weekdays,
                 end_date: end_date,
                 instruction: instruction,
                 approved_text: approved_text
               })

      assert trigger.status == "active"
      assert trigger.schedule_type == "weekly"
      assert trigger.time == time
      assert trigger.weekdays == weekdays
      assert trigger.end_date == end_date
      assert trigger.scheduled_at != nil

      assert_enqueued(
        worker: ActiveTriggerWorker,
        args: %{"trigger_id" => trigger.id}
      )
    end

    test "rejects weekly trigger with empty weekdays",
         %{professional: professional, patient: patient} do
      assert {:error, {:empty_weekdays, _msg}} =
               Triggers.create_and_approve_trigger(professional, patient.id, %{
                 schedule_type: "weekly",
                 time: ~T[10:00:00],
                 weekdays: [],
                 instruction: "Instruccion",
                 approved_text: "Texto"
               })
    end

    test "rejects trigger if end_date is before first scheduled occurrence",
         %{professional: professional, patient: patient} do
      past_end_date = Date.utc_today() |> Date.add(-1)

      assert {:error, {:invalid_end_date, _msg}} =
               Triggers.create_and_approve_trigger(professional, patient.id, %{
                 schedule_type: "daily",
                 time: ~T[10:00:00],
                 end_date: past_end_date,
                 instruction: "Instruccion",
                 approved_text: "Texto"
               })
    end

    test "Message.changeset does not cast trigger_id from untrusted attrs (B5)" do
      untrusted_id = Ecto.UUID.generate()

      changeset_atom =
        Clinical.Message.changeset(%Clinical.Message{}, %{
          patient_id: Ecto.UUID.generate(),
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: <<1, 2, 3>>,
          timestamp: DateTime.utc_now(),
          trigger_id: untrusted_id
        })

      refute Map.has_key?(changeset_atom.changes, :trigger_id)

      changeset_str =
        Clinical.Message.changeset(%Clinical.Message{}, %{
          "patient_id" => Ecto.UUID.generate(),
          "direction" => "outbound",
          "behavior_type" => "spontaneous",
          "encrypted_content" => <<1, 2, 3>>,
          "timestamp" => DateTime.utc_now(),
          "trigger_id" => untrusted_id
        })

      refute Map.has_key?(changeset_str.changes, :trigger_id)
    end

    test "rejects non-owning professional (S9)", %{patient: patient} do
      other = fixture_professional_and_patient()
      future_date = Date.utc_today() |> Date.add(2)

      assert {:error, :unauthorized} =
               Triggers.create_and_approve_trigger(other.professional, patient.id, %{
                 instruction: "Instruccion",
                 approved_text: "Texto aprobado",
                 date: future_date,
                 time: ~T[12:00:00]
               })

      refute_enqueued(worker: ActiveTriggerWorker)
    end

    test "generate_preview/3 authorizes owner and invokes TriggerPreviewChain",
         %{professional: professional, patient: patient} do
      other = fixture_professional_and_patient()

      assert {:error, :unauthorized} =
               Triggers.generate_preview(other.professional, patient.id, "Alguna instrucción")

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn %{instruction: inst} ->
        assert inst == "Recordar practicar respiración"
        {:ok, %{draft: "Hola, ¿cómo te fue hoy con la respiración?"}}
      end)

      assert {:ok, %{draft: "Hola, ¿cómo te fue hoy con la respiración?"}} =
               Triggers.generate_preview(
                 professional,
                 patient.id,
                 "Recordar practicar respiración"
               )
    end
  end

  describe "get_produced_message/3" do
    test "retrieves produced message with decrypted content for owner",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Mensaje producido descifrado",
          date: future_date,
          time: ~T[14:00:00]
        })

      # Create a message with trigger_id
      {:ok, dek} = Clinical.patient_dek(patient, "test_produce")
      {:ok, enc_content} = PatientVault.encrypt("Mensaje producido descifrado", dek)

      {:ok, message} =
        %Clinical.Message{}
        |> Clinical.Message.changeset(%{
          patient_id: patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_content,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert()

      assert {:ok, retrieved_message, text} =
               Triggers.get_produced_message(professional, patient.id, message.id)

      assert retrieved_message.id == message.id
      assert text == "Mensaje producido descifrado"

      other = fixture_professional_and_patient()

      assert {:error, :unauthorized} =
               Triggers.get_produced_message(other.professional, patient.id, message.id)
    end
  end

  describe "malformed UUID handling at context boundary (B6)" do
    test "returns :unauthorized when patient_id is not a valid UUID", %{
      professional: professional
    } do
      invalid_patient_id = "malformed-not-a-uuid"

      assert {:error, :unauthorized} =
               Triggers.generate_preview(professional, invalid_patient_id, "Instruccion")

      assert {:error, :unauthorized} =
               Triggers.create_and_approve_trigger(professional, invalid_patient_id, %{
                 instruction: "Instruccion",
                 approved_text: "Texto",
                 date: Date.utc_today() |> Date.add(1),
                 time: ~T[10:00:00]
               })

      assert {:error, :unauthorized} =
               Triggers.list_active_triggers(professional, invalid_patient_id)

      assert {:error, :unauthorized} =
               Triggers.get_trigger(professional, invalid_patient_id, Ecto.UUID.generate())

      assert {:error, :unauthorized} =
               Triggers.list_firings(professional, invalid_patient_id)

      assert {:error, :unauthorized} =
               Triggers.get_produced_message(
                 professional,
                 invalid_patient_id,
                 Ecto.UUID.generate()
               )
    end

    test "returns :not_found when trigger_id or message_id is not a valid UUID",
         %{professional: professional, patient: patient} do
      assert {:error, :not_found} =
               Triggers.get_trigger(professional, patient.id, "malformed-trigger-uuid")

      assert {:error, :not_found} =
               Triggers.get_produced_message(professional, patient.id, "malformed-message-uuid")
    end
  end

  describe "pause_active_triggers_for_crisis/1 and resume_trigger/3 (Issue #443)" do
    test "pauses all active triggers for a patient on crisis, deletes scheduled jobs, and audits",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger1} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion 1",
          approved_text: "Texto 1",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, trigger2} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion 2",
          approved_text: "Texto 2",
          schedule_type: "daily",
          time: ~T[11:00:00]
        })

      # Create an inactive trigger for same patient
      {:ok, trigger3} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion 3",
          approved_text: "Texto 3",
          date: future_date,
          time: ~T[12:00:00]
        })

      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger3.id)

      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger1.id})
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger2.id})

      assert {:ok, 2} = Triggers.pause_active_triggers_for_crisis(patient.id)

      # Active triggers moved to paused_by_crisis
      assert Repo.get!(Trigger, trigger1.id).status == "paused_by_crisis"
      assert Repo.get!(Trigger, trigger2.id).status == "paused_by_crisis"

      # Inactive trigger remains inactive
      assert Repo.get!(Trigger, trigger3.id).status == "inactive"

      # Scheduled jobs were deleted
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger1.id})
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger2.id})

      # Audit logs were written
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

    test "resumes a paused-by-crisis trigger for owning professional, reschedules job, and audits",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)
      assert Repo.get!(Trigger, trigger.id).status == "paused_by_crisis"
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Resume trigger
      assert {:ok, resumed} = Triggers.resume_trigger(professional, patient.id, trigger.id)
      assert resumed.status == "active"
      assert Repo.get!(Trigger, trigger.id).status == "active"

      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      assert Repo.get_by(AuditLog,
               resource_id: trigger.id,
               action: "trigger_resumed",
               professional_id: professional.id
             )
    end

    test "cannot be resumed by a non-owning professional",
         %{professional: professional, patient: patient} do
      other = fixture_professional_and_patient()
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)

      assert {:error, :unauthorized} =
               Triggers.resume_trigger(other.professional, patient.id, trigger.id)
    end

    test "cannot resume expired one-shot trigger",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)

      # Expire scheduled_at
      past_dt = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      trigger
      |> Ecto.Changeset.change(%{scheduled_at: past_dt})
      |> Repo.update!()

      assert {:error, {:expired_schedule, _msg}} =
               Triggers.resume_trigger(professional, patient.id, trigger.id)
    end

    test "activate_trigger rejects paused_by_crisis triggers",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)

      assert {:error, :paused_by_crisis} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)
    end

    test "deactivate_trigger safely deactivates paused_by_crisis triggers (CORR-01)",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, 1} = Triggers.pause_active_triggers_for_crisis(patient.id)
      assert Repo.get!(Trigger, trigger.id).status == "paused_by_crisis"

      assert {:ok, deactivated} =
               Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      assert deactivated.status == "inactive"
      assert Repo.get!(Trigger, trigger.id).status == "inactive"

      assert Repo.get_by(AuditLog,
               resource_id: trigger.id,
               action: "trigger_deactivated",
               professional_id: professional.id
             )
    end
  end

  describe "list_active_triggers/2 and get_trigger/3" do
    test "lists and retrieves triggers with decrypted fields for owner",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion secreta",
          approved_text: "Texto aprobado para el paciente",
          date: future_date,
          time: ~T[14:00:00]
        })

      assert {:ok, [listed]} = Triggers.list_active_triggers(professional, patient.id)
      assert listed.id == trigger.id
      assert listed.decrypted_instruction == "Instruccion secreta"
      assert listed.decrypted_approved_text == "Texto aprobado para el paciente"

      assert {:ok, fetched} = Triggers.get_trigger(professional, patient.id, trigger.id)
      assert fetched.id == trigger.id
      assert fetched.decrypted_instruction == "Instruccion secreta"
      assert fetched.decrypted_approved_text == "Texto aprobado para el paciente"
    end

    test "forbids other professional from listing or getting triggers",
         %{professional: professional, patient: patient} do
      other = fixture_professional_and_patient()
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[14:00:00]
        })

      assert {:error, :unauthorized} =
               Triggers.list_active_triggers(other.professional, patient.id)

      assert {:error, :unauthorized} =
               Triggers.get_trigger(other.professional, patient.id, trigger.id)
    end
  end

  describe "TriggerFiring schema validations (S4)" do
    alias Alethea.Triggers.TriggerFiring

    test "requires message_id when status is fired", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

      changeset =
        TriggerFiring.changeset(%TriggerFiring{}, %{
          trigger_id: trigger.id,
          message_id: nil,
          status: "fired",
          fired_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).message_id
    end

    test "allows nil message_id when status is skipped", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

      changeset =
        TriggerFiring.changeset(%TriggerFiring{}, %{
          trigger_id: trigger.id,
          message_id: nil,
          status: "skipped",
          fired_at: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "rejects message_id when status is skipped", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

      changeset =
        TriggerFiring.changeset(%TriggerFiring{}, %{
          trigger_id: trigger.id,
          message_id: Ecto.UUID.generate(),
          status: "skipped",
          fired_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert errors_on(changeset).message_id != []
    end

    test "allows message_id when status is not_delivered (#445)", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

      changeset =
        TriggerFiring.changeset(%TriggerFiring{}, %{
          trigger_id: trigger.id,
          message_id: Ecto.UUID.generate(),
          status: "not_delivered",
          fired_at: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "requires message_id when status is not_delivered (#445)", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

      changeset =
        TriggerFiring.changeset(%TriggerFiring{}, %{
          trigger_id: trigger.id,
          message_id: nil,
          status: "not_delivered",
          fired_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).message_id
    end

    test "allows paused_by_delivery_failures status and consecutive_delivery_failures on Trigger (#445)",
         %{patient: patient, professional: professional} do
      attrs = %{
        patient_id: patient.id,
        professional_id: professional.id,
        instruction: "Instruccion",
        scheduled_at: DateTime.utc_now(),
        timezone: "America/Santiago",
        status: "paused_by_delivery_failures",
        schedule_type: "once",
        consecutive_delivery_failures: 3
      }

      changeset = Trigger.changeset(%Trigger{}, attrs)
      assert changeset.valid?

      neg_changeset =
        Trigger.changeset(%Trigger{}, Map.put(attrs, :consecutive_delivery_failures, -1))

      refute neg_changeset.valid?

      assert "must be greater than or equal to 0" in errors_on(neg_changeset).consecutive_delivery_failures

      nil_changeset =
        Trigger.changeset(%Trigger{}, Map.put(attrs, :consecutive_delivery_failures, nil))

      refute nil_changeset.valid?
      assert "can't be blank" in errors_on(nil_changeset).consecutive_delivery_failures
    end
  end

  # ----------------------------------------------------------------
  # Elicited window (#447): a patient reply within 2h of a DELIVERED
  # Trigger activo message is prompted behavior, not spontaneous.
  # ----------------------------------------------------------------

  describe "elicited_window_open?/2 (#447)" do
    setup %{patient: patient} do
      {:ok, dek} = Clinical.patient_dek(patient, "test_elicited_window")
      {:ok, enc} = PatientVault.encrypt("Texto de trigger", dek)

      %{enc_text: enc}
    end

    defp insert_elicited_trigger!(patient, enc_text) do
      %Trigger{}
      |> Trigger.changeset(%{
        patient_id: patient.id,
        professional_id: patient.professional_id,
        instruction: enc_text,
        draft_message: enc_text,
        approved_text: enc_text,
        scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
        timezone: "America/Santiago",
        status: "fired"
      })
      |> Repo.insert!()
    end

    defp insert_trigger_message!(patient, trigger, delivery_state, minutes_ago) do
      {:ok, dek} = Clinical.patient_dek(patient, "test_elicited_window_message")
      {:ok, enc} = PatientVault.encrypt("Mensaje programado", dek)

      %Clinical.Message{}
      |> Clinical.Message.changeset(%{
        patient_id: patient.id,
        direction: "outbound",
        behavior_type: "spontaneous",
        encrypted_content: enc,
        timestamp:
          DateTime.utc_now()
          |> DateTime.add(-minutes_ago, :minute)
          |> DateTime.truncate(:second)
      })
      |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
      |> Ecto.Changeset.put_change(:delivery_state, delivery_state)
      |> Repo.insert!()
    end

    defp window_open?(patient, minutes_ago) do
      timestamp =
        DateTime.utc_now() |> DateTime.add(-minutes_ago, :minute) |> DateTime.truncate(:second)

      Triggers.elicited_window_open?(patient.id, timestamp)
    end

    test "returns true when a delivered trigger message is within 2 hours", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 30)

      assert window_open?(patient, 0)
    end

    test "returns true exactly at the 2 hour boundary (inclusive)", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 120)

      assert window_open?(patient, 0)
    end

    test "returns false just past the 2 hour boundary", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 121)

      refute window_open?(patient, 0)
    end

    test "returns false well after the window", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 240)

      refute window_open?(patient, 0)
    end

    test "returns false when the newest trigger message is not delivered (pending)", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "pending", 30)

      refute window_open?(patient, 0)
    end

    test "returns false when the newest trigger message failed delivery", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "failed", 30)

      refute window_open?(patient, 0)
    end

    test "returns false when the newest trigger message delivery is ambiguous", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "ambiguous", 30)

      refute window_open?(patient, 0)
    end

    test "returns false when the message has no trigger provenance", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      message = insert_trigger_message!(patient, trigger, "sent", 30)

      Repo.update_all(
        from(m in Clinical.Message, where: m.id == ^message.id),
        set: [trigger_id: nil]
      )

      refute window_open?(patient, 0)
    end

    test "a newer pending trigger message does not mask an older delivered one", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 30)
      insert_trigger_message!(patient, trigger, "pending", 5)

      assert window_open?(patient, 0)
    end

    test "returns false when the reply predates the trigger delivery", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 30)

      # Inbound written 60 minutes ago: 30 minutes BEFORE the trigger was delivered.
      refute window_open?(patient, 60)
    end

    test "returns false when the patient has no trigger messages", %{patient: patient} do
      refute window_open?(patient, 0)
    end

    test "returns false for a nil inbound timestamp", %{
      patient: patient,
      enc_text: enc_text
    } do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 30)

      refute Triggers.elicited_window_open?(patient.id, nil)
    end

    test "does not cross patients", %{patient: patient, enc_text: enc_text} do
      trigger = insert_elicited_trigger!(patient, enc_text)
      insert_trigger_message!(patient, trigger, "sent", 30)

      other = fixture_professional_and_patient()

      refute window_open?(other.patient, 0)
    end
  end

  describe "delivery failure handling and lifecycle (#445)" do
    alias Alethea.Triggers.TriggerFiring

    test "handle_delivery_failure updates firing to not_delivered and increments counter", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

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

      firing =
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

      assert Repo.get!(TriggerFiring, firing.id).status == "not_delivered"
      reloaded = Repo.get!(Trigger, trigger.id)
      assert reloaded.consecutive_delivery_failures == 1
      assert reloaded.status == "active"

      # Calling it again on the same message is idempotent: does not increment counter again
      assert :ok = Triggers.handle_delivery_failure(message.id)
      reloaded_again = Repo.get!(Trigger, trigger.id)
      assert reloaded_again.consecutive_delivery_failures == 1
    end

    test "handle_delivery_failure pauses trigger after 3 consecutive failures", %{
      patient: patient,
      professional: professional
    } do
      future_date = Date.add(Date.utc_today(), 1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          schedule_type: "daily",
          time: ~T[11:00:00],
          date: future_date
        })

      # Set failure count to 2
      trigger
      |> Trigger.changeset(%{consecutive_delivery_failures: 2})
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

      firing =
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

      assert Repo.get!(TriggerFiring, firing.id).status == "not_delivered"
      reloaded = Repo.get!(Trigger, trigger.id)
      assert reloaded.consecutive_delivery_failures == 3
      assert reloaded.status == "paused_by_delivery_failures"

      assert Repo.get_by(AuditLog,
               resource_id: trigger.id,
               action: "trigger_paused_by_delivery_failures"
             )
    end

    test "success in between resets consecutive_delivery_failures", %{
      patient: patient,
      professional: professional
    } do
      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: Date.add(Date.utc_today(), 1),
          time: ~T[11:00:00]
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 2 failures
      for _ <- 1..2 do
        msg =
          %Clinical.Message{}
          |> Clinical.Message.changeset(%{
            patient_id: patient.id,
            direction: "outbound",
            behavior_type: "spontaneous",
            encrypted_content: trigger.approved_text,
            timestamp: now
          })
          |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
          |> Repo.insert!()

        Triggers.handle_delivery_failure(msg.id)
      end

      assert Repo.get!(Trigger, trigger.id).consecutive_delivery_failures == 2

      # 1 success in between
      success_msg =
        %Clinical.Message{}
        |> Clinical.Message.changeset(%{
          patient_id: patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: trigger.approved_text,
          timestamp: now
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      assert :ok = Triggers.handle_delivery_success(success_msg.id)
      assert Repo.get!(Trigger, trigger.id).consecutive_delivery_failures == 0

      # 2 more failures do not pause the trigger (count is now 2, not 4)
      for _ <- 1..2 do
        msg =
          %Clinical.Message{}
          |> Clinical.Message.changeset(%{
            patient_id: patient.id,
            direction: "outbound",
            behavior_type: "spontaneous",
            encrypted_content: trigger.approved_text,
            timestamp: now
          })
          |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
          |> Repo.insert!()

        Triggers.handle_delivery_failure(msg.id)
      end

      reloaded = Repo.get!(Trigger, trigger.id)
      assert reloaded.consecutive_delivery_failures == 2
      assert reloaded.status == "active"
    end

    test "resuming a trigger paused by delivery failures resets counter and activates trigger", %{
      patient: patient,
      professional: professional
    } do
      future_date = Date.add(Date.utc_today(), 2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion diaria",
          approved_text: "Texto diario",
          schedule_type: "daily",
          time: ~T[11:00:00],
          date: future_date
        })

      trigger
      |> Trigger.changeset(%{
        status: "paused_by_delivery_failures",
        consecutive_delivery_failures: 3
      })
      |> Repo.update!()

      assert {:ok, resumed} = Triggers.resume_trigger(professional, patient.id, trigger.id)
      assert resumed.status == "active"
      assert resumed.consecutive_delivery_failures == 0

      assert Repo.get_by(AuditLog,
               resource_id: trigger.id,
               action: "trigger_resumed"
             )
    end

    test "activate_trigger rejects a trigger paused by delivery failures", %{
      patient: patient,
      professional: professional
    } do
      future_date = Date.add(Date.utc_today(), 2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion diaria",
          approved_text: "Texto diario",
          schedule_type: "daily",
          time: ~T[11:00:00],
          date: future_date
        })

      trigger
      |> Trigger.changeset(%{
        status: "paused_by_delivery_failures",
        consecutive_delivery_failures: 3
      })
      |> Repo.update!()

      assert {:error, :paused_by_delivery_failures} =
               Triggers.activate_trigger(professional, patient.id, trigger.id)
    end

    test "deactivate_trigger can deactivate a trigger paused by delivery failures", %{
      patient: patient,
      professional: professional
    } do
      future_date = Date.add(Date.utc_today(), 2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion diaria",
          approved_text: "Texto diario",
          schedule_type: "daily",
          time: ~T[11:00:00],
          date: future_date
        })

      trigger
      |> Trigger.changeset(%{
        status: "paused_by_delivery_failures",
        consecutive_delivery_failures: 3
      })
      |> Repo.update!()

      assert {:ok, deactivated} =
               Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      assert deactivated.status == "inactive"
    end

    test "get_trigger_summary includes paused_by_delivery_failures count", %{
      patient: patient,
      professional: professional
    } do
      future_date = Date.add(Date.utc_today(), 2)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[11:00:00]
        })

      trigger
      |> Trigger.changeset(%{
        status: "paused_by_delivery_failures",
        consecutive_delivery_failures: 3
      })
      |> Repo.update!()

      assert {:ok, summary} = Triggers.get_trigger_summary(professional, patient.id)
      assert summary.by_status.paused_by_delivery_failures == 1
      assert summary.active_kind.paused_by_delivery_failures == 1
    end
  end
end
