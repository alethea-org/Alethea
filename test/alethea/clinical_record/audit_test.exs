defmodule Alethea.ClinicalRecord.AuditTest do
  @moduledoc """
  Tests for `Alethea.ClinicalRecord.Audit` (sdd/clinical-record-foundation,
  task 2.3). Proves the closed-struct contract: `changeset/1` rejects any
  action/resource_type/outcome outside a fixed vocabulary, and `details`
  can only ever be `%{"outcome" => "success" | "denied"}` — unlike
  `Alethea.Accounts.log_action/1`, whose `details` map is unconstrained.
  """
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord.Audit

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "audit-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Audit"
      })

    %{professional: professional}
  end

  describe "changeset/1 — happy path" do
    test "builds a content-free success row for a target_behavior_created action", %{
      professional: professional
    } do
      resource_id = Ecto.UUID.generate()

      changeset =
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "target_behavior_created",
          resource_type: "target_behavior",
          resource_id: resource_id,
          outcome: "success"
        })

      assert changeset.valid?
      assert get_change(changeset, :details) == %{"outcome" => "success"}
      assert get_change(changeset, :action) == "target_behavior_created"
      assert get_change(changeset, :resource_id) == resource_id
    end

    test "builds a content-free success row for a clinical_note_created action (triangulation)",
         %{
           professional: professional
         } do
      resource_id = Ecto.UUID.generate()

      changeset =
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "clinical_note_created",
          resource_type: "clinical_note",
          resource_id: resource_id,
          outcome: "success"
        })

      assert changeset.valid?
      assert get_change(changeset, :details) == %{"outcome" => "success"}
    end
  end

  describe "changeset/1 — closed vocabulary" do
    test "rejects an action outside the fixed action list", %{professional: professional} do
      changeset =
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "patient_deleted",
          resource_type: "patient",
          outcome: "denied"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).action
    end

    test "rejects a resource_type outside the fixed resource_type list", %{
      professional: professional
    } do
      changeset =
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "clinical_record_access_denied",
          resource_type: "message",
          outcome: "denied"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).resource_type
    end

    test "rejects an outcome outside {success, denied}", %{professional: professional} do
      changeset =
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "clinical_record_access_denied",
          resource_type: "patient",
          outcome: "partial"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).outcome
    end
  end

  describe "log_denied/3" do
    test "persists a single content-free denial audit row", %{professional: professional} do
      patient_id = Ecto.UUID.generate()

      assert {:ok, %Audit{} = audit} = Audit.log_denied(professional.id, patient_id, "patient")

      assert audit.action == "clinical_record_access_denied"
      assert audit.resource_type == "patient"
      assert audit.resource_id == patient_id
      assert audit.details == %{"outcome" => "denied"}
    end
  end
end
