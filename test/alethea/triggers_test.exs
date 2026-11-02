defmodule Alethea.TriggersTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.TriggersFixtures
  import Mox

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
end
