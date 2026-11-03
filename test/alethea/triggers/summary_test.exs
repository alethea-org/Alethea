defmodule Alethea.Triggers.SummaryTest do
  use Alethea.DataCase, async: false

  alias Alethea.Clinical
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger

  import Alethea.TriggersFixtures

  setup do
    %{professional: professional, patient: patient, kek: kek} =
      fixture_professional_and_patient()

    %{professional: professional, patient: patient, kek: kek}
  end

  defp create_trigger!(professional, patient, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    future = DateTime.add(now, 3600, :second)

    {:ok, dek} = Clinical.patient_dek(patient, "test")
    {:ok, enc_inst} = PatientVault.encrypt("Instrucción clínica", dek)
    {:ok, enc_draft} = PatientVault.encrypt("Borrador", dek)

    enc_approved =
      if Map.get(attrs, :approved, true) do
        {:ok, enc} = PatientVault.encrypt("Aprobado", dek)
        enc
      else
        nil
      end

    status = Map.get(attrs, :status, "active")

    params = %{
      patient_id: patient.id,
      professional_id: professional.id,
      instruction: enc_inst,
      draft_message: enc_draft,
      approved_text: enc_approved,
      scheduled_at: Map.get(attrs, :scheduled_at, future),
      timezone: patient.timezone || "America/Santiago",
      status: status,
      schedule_type: Map.get(attrs, :schedule_type, "once"),
      approval_revision: Map.get(attrs, :approval_revision, 1)
    }

    %Trigger{}
    |> Trigger.changeset(params)
    |> Repo.insert!()
  end

  describe "get_trigger_summary/2" do
    test "returns zero counts by kind and status for patient with no triggers", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, summary} = Triggers.get_trigger_summary(professional, patient.id)

      assert summary.total == 0

      # Kind counts
      assert summary.by_kind.active.total == 0
      assert summary.by_kind.active.active == 0
      assert summary.by_kind.active.inactive == 0
      assert summary.by_kind.active.fired == 0
      assert summary.by_kind.active.needs_approval == 0

      # Reactive kind is all 0
      assert summary.by_kind.reactive.total == 0
      assert summary.by_kind.reactive.active == 0
      assert summary.by_kind.reactive.inactive == 0
      assert summary.by_kind.reactive.fired == 0
      assert summary.by_kind.reactive.needs_approval == 0

      # Status counts
      assert summary.by_status.active == 0
      assert summary.by_status.inactive == 0
      assert summary.by_status.fired == 0
      assert summary.needs_approval == 0
    end

    test "aggregates counts accurately across active, inactive, and fired triggers", %{
      professional: professional,
      patient: patient
    } do
      create_trigger!(professional, patient, %{status: "active"})
      create_trigger!(professional, patient, %{status: "active"})
      create_trigger!(professional, patient, %{status: "inactive"})
      create_trigger!(professional, patient, %{status: "fired"})

      assert {:ok, summary} = Triggers.get_trigger_summary(professional, patient.id)

      assert summary.total == 4
      assert summary.by_status.active == 2
      assert summary.by_status.inactive == 1
      assert summary.by_status.fired == 1
      assert summary.needs_approval == 0

      assert summary.by_kind.active.total == 4
      assert summary.by_kind.active.active == 2
      assert summary.by_kind.active.inactive == 1
      assert summary.by_kind.active.fired == 1

      assert summary.by_kind.reactive.total == 0
    end

    test "counts unapproved triggers under needs_approval without double-counting total", %{
      professional: professional,
      patient: patient
    } do
      # 1 active approved, 1 active unapproved
      create_trigger!(professional, patient, %{status: "active", approved: true})
      create_trigger!(professional, patient, %{status: "active", approved: false})

      assert {:ok, summary} = Triggers.get_trigger_summary(professional, patient.id)

      assert summary.total == 2
      assert summary.by_status.active == 2
      assert summary.needs_approval == 1
      assert summary.by_kind.active.needs_approval == 1
    end

    test "enforces ownership: returns unauthorized for foreign professional", %{
      patient: patient
    } do
      %{professional: other_pro} = fixture_professional_and_patient()

      assert {:error, :unauthorized} = Triggers.get_trigger_summary(other_pro, patient.id)
    end

    test "returns unauthorized for invalid UUID or non-existent patient", %{
      professional: professional
    } do
      assert {:error, :unauthorized} =
               Triggers.get_trigger_summary(professional, "not-a-uuid")

      assert {:error, :unauthorized} =
               Triggers.get_trigger_summary(professional, Ecto.UUID.generate())
    end

    test "reflects lifecycle mutations: deactivation, instruction edit, and reapproval", %{
      professional: professional,
      patient: patient
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      future = DateTime.add(now, 3600, :second)

      trigger =
        create_trigger!(professional, patient, %{
          status: "active",
          approved: true,
          scheduled_at: future
        })

      # Initial state: 1 active, 0 needs_approval
      {:ok, s1} = Triggers.get_trigger_summary(professional, patient.id)
      assert s1.by_status.active == 1
      assert s1.by_status.inactive == 0
      assert s1.needs_approval == 0

      # Deactivate: 0 active, 1 inactive
      {:ok, deactivated} =
        Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      assert deactivated.status == "inactive"

      {:ok, s2} = Triggers.get_trigger_summary(professional, patient.id)
      assert s2.by_status.active == 0
      assert s2.by_status.inactive == 1
      assert s2.needs_approval == 0

      # Update instruction on inactive trigger: needs_approval becomes 1, status remains inactive
      {:ok, updated} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instrucción editada"
        )

      assert is_nil(updated.approved_text)

      {:ok, s3} = Triggers.get_trigger_summary(professional, patient.id)
      assert s3.by_status.inactive == 1
      assert s3.needs_approval == 1

      # Reapprove: needs_approval returns to 0
      {:ok, reapproved} =
        Triggers.reapprove_trigger(professional, patient.id, trigger.id, %{
          expected_revision: updated.approval_revision,
          approved_text: "Texto aprobado renovado"
        })

      refute is_nil(reapproved.approved_text)

      {:ok, s4} = Triggers.get_trigger_summary(professional, patient.id)
      assert s4.by_status.inactive == 1
      assert s4.needs_approval == 0
    end

    test "supports get_triggers_summary/2 delegate", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, summary} = Triggers.get_triggers_summary(professional, patient.id)
      assert summary.total == 0
    end
  end
end
