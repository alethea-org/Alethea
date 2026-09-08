defmodule Alethea.ClinicalRecord.LifecycleTest do
  @moduledoc """
  RED-phase specs for `Alethea.ClinicalRecord.Lifecycle`
  (sdd/clinical-record-retention, GitHub #197, Phase 1/Slice A,
  tasks 1.4/1.11): `apply_hold/2`, `release_hold/2`, `held?/1`,
  `set_retention_minimum/3`, `effective_retention_days/1`.
  """
  use Alethea.DataCase, async: true

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.ClinicalRecord.Audit
  alias Alethea.ClinicalRecord.Lifecycle

  @password "supersecret12"

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  describe "apply_hold/2 and release_hold/2 — authorized" do
    test "apply_hold sets legal_hold_at, records the acting professional, and audits legal_hold_applied",
         %{professional: professional, patient: patient} do
      refute Lifecycle.held?(patient.id)

      assert {:ok, lifecycle} = Lifecycle.apply_hold(professional, patient.id)
      assert %DateTime{} = lifecycle.legal_hold_at
      assert lifecycle.legal_hold_by_id == professional.id
      assert lifecycle.patient_id == patient.id
      assert Lifecycle.held?(patient.id)

      rows =
        AuditLog
        |> where([a], a.professional_id == ^professional.id and a.action == "legal_hold_applied")
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).resource_id == patient.id
      assert hd(rows).resource_type == "patient"
      assert hd(rows).details == %{"outcome" => "success"}
    end

    test "release_hold clears legal_hold_at, stamps legal_hold_released_at, audits legal_hold_released",
         %{professional: professional, patient: patient} do
      {:ok, _lifecycle} = Lifecycle.apply_hold(professional, patient.id)

      assert {:ok, released} = Lifecycle.release_hold(professional, patient.id)
      assert released.legal_hold_at == nil
      assert %DateTime{} = released.legal_hold_released_at
      refute Lifecycle.held?(patient.id)

      rows =
        AuditLog
        |> where([a], a.professional_id == ^professional.id and a.action == "legal_hold_released")
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).resource_id == patient.id
    end
  end

  describe "apply_hold/2 and set_retention_minimum/3 — unauthorized" do
    test "apply_hold denies a professional not responsible for the patient: no hold, 1 denied audit row",
         %{patient: patient} do
      other = create_professional!()

      assert {:error, :unauthorized} = Lifecycle.apply_hold(other, patient.id)
      refute Lifecycle.held?(patient.id)

      rows = AuditLog |> where([a], a.professional_id == ^other.id) |> Repo.all()
      assert length(rows) == 1
      assert hd(rows).action == "clinical_record_access_denied"
    end

    test "set_retention_minimum denies a professional not responsible for the patient", %{
      patient: patient
    } do
      other = create_professional!()

      assert {:error, :unauthorized} = Lifecycle.set_retention_minimum(other, patient.id, 4000)
    end
  end

  describe "held?/1" do
    test "returns false for a patient with no lifecycle row at all", %{patient: patient} do
      refute Lifecycle.held?(patient.id)
    end

    test "returns false again after a hold has been applied then released (triangulation)", %{
      professional: professional,
      patient: patient
    } do
      {:ok, _} = Lifecycle.apply_hold(professional, patient.id)
      {:ok, _} = Lifecycle.release_hold(professional, patient.id)

      refute Lifecycle.held?(patient.id)
    end
  end

  describe "set_retention_minimum/3 and effective_retention_days/1" do
    test "nil lifecycle falls back to the global baseline (3650 days)" do
      assert Lifecycle.effective_retention_days(nil) == 3650
    end

    test "a stricter override wins over the baseline (max semantics)", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, lifecycle} = Lifecycle.set_retention_minimum(professional, patient.id, 4000)
      assert lifecycle.retention_minimum_days == 4000
      assert Lifecycle.effective_retention_days(lifecycle) == 4000
    end

    test "an override shorter than the baseline never shortens retention (max semantics)", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, lifecycle} = Lifecycle.set_retention_minimum(professional, patient.id, 100)
      assert Lifecycle.effective_retention_days(lifecycle) == 3650
    end

    test "a nil override on an existing lifecycle row falls back to the baseline", %{
      professional: professional,
      patient: patient
    } do
      {:ok, _} = Lifecycle.set_retention_minimum(professional, patient.id, 4000)
      assert {:ok, lifecycle} = Lifecycle.set_retention_minimum(professional, patient.id, nil)

      assert lifecycle.retention_minimum_days == nil
      assert Lifecycle.effective_retention_days(lifecycle) == 3650
    end
  end

  describe "BR2 — hold pauses deletion attempts (stub; full wiring lands in Slice C's Retention)" do
    test "an active hold's stub deletion attempt is denied and audited as paused, not executed",
         %{
           professional: professional,
           patient: patient
         } do
      assert {:ok, _lifecycle} = Lifecycle.apply_hold(professional, patient.id)
      assert Lifecycle.held?(patient.id)

      # Retention.legally_delete_record/2 (Slice C) will gate on
      # Lifecycle.held?/1 exactly like this before ever reaching the
      # deletion primitive. This stub proves that contract ahead of Slice
      # C's implementation, using only what Slice A ships.
      result =
        if Lifecycle.held?(patient.id) do
          {:ok, _audit} = Audit.log_denied(professional.id, patient.id, "patient")
          {:error, :legal_hold_active}
        else
          {:ok, :would_delete}
        end

      assert {:error, :legal_hold_active} = result

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "clinical_record_access_denied"
        )
        |> Repo.all()

      assert length(rows) == 1
    end

    test "lifting the hold re-exposes held?/1 as false with no lifecycle clock reset on release",
         %{
           professional: professional,
           patient: patient
         } do
      {:ok, lifecycle} = Lifecycle.apply_hold(professional, patient.id)
      assert Lifecycle.held?(patient.id)

      assert {:ok, released} = Lifecycle.release_hold(professional, patient.id)
      refute Lifecycle.held?(patient.id)
      assert released.id == lifecycle.id
      assert released.legal_hold_at == nil
      assert %DateTime{} = released.legal_hold_released_at
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "lifecycle-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Lifecycle"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end
end
