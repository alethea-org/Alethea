defmodule Alethea.ClinicalRecord.ClinicianObservationTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.ClinicianObservation`
  (sdd/alethea/issue-195-clinical-review-workbench, PR1b task 2.1). Unlike
  `Alethea.ClinicalRecord.ConsultationEvidence`, this schema is mutable
  (`update_changeset/2` exists, body only) and carries no source columns —
  spec: "it carries no source_kind/source_id reference".
  """
  use Alethea.DataCase, async: true

  alias Alethea.ClinicalRecord.ClinicianObservation

  @valid_attrs %{
    encrypted_body: <<1, 2, 3>>,
    occurred_at: DateTime.utc_now(),
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate(),
    target_behavior_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields" do
      changeset = ClinicianObservation.changeset(%ClinicianObservation{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :encrypted_body) == <<1, 2, 3>>
      assert get_change(changeset, :patient_id) == @valid_attrs.patient_id
      assert get_change(changeset, :professional_id) == @valid_attrs.professional_id
      assert get_change(changeset, :target_behavior_id) == @valid_attrs.target_behavior_id
    end
  end

  describe "changeset/2 — no source columns" do
    test "carries no source_kind or source_id fields at all" do
      refute Map.has_key?(%ClinicianObservation{}, :source_kind)
      refute Map.has_key?(%ClinicianObservation{}, :source_id)
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects a missing encrypted_body" do
      changeset =
        ClinicianObservation.changeset(
          %ClinicianObservation{},
          Map.delete(@valid_attrs, :encrypted_body)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_body
    end

    test "rejects a missing occurred_at" do
      changeset =
        ClinicianObservation.changeset(
          %ClinicianObservation{},
          Map.delete(@valid_attrs, :occurred_at)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).occurred_at
    end

    test "rejects a missing patient_id" do
      changeset =
        ClinicianObservation.changeset(
          %ClinicianObservation{},
          Map.delete(@valid_attrs, :patient_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "rejects a missing professional_id" do
      changeset =
        ClinicianObservation.changeset(
          %ClinicianObservation{},
          Map.delete(@valid_attrs, :professional_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).professional_id
    end

    test "rejects a missing target_behavior_id" do
      changeset =
        ClinicianObservation.changeset(
          %ClinicianObservation{},
          Map.delete(@valid_attrs, :target_behavior_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_behavior_id
    end
  end

  describe "update_changeset/2 — body only" do
    test "casts encrypted_body only" do
      observation = %ClinicianObservation{
        encrypted_body: <<1, 2, 3>>,
        patient_id: Ecto.UUID.generate(),
        professional_id: Ecto.UUID.generate(),
        target_behavior_id: Ecto.UUID.generate()
      }

      changeset =
        ClinicianObservation.update_changeset(observation, %{encrypted_body: <<9, 9, 9>>})

      assert changeset.valid?
      assert get_change(changeset, :encrypted_body) == <<9, 9, 9>>
    end

    test "ignores an attempt to change patient_id via update_changeset" do
      observation = %ClinicianObservation{
        encrypted_body: <<1, 2, 3>>,
        patient_id: Ecto.UUID.generate(),
        professional_id: Ecto.UUID.generate(),
        target_behavior_id: Ecto.UUID.generate()
      }

      changeset =
        ClinicianObservation.update_changeset(observation, %{
          encrypted_body: <<9, 9, 9>>,
          patient_id: Ecto.UUID.generate()
        })

      refute Map.has_key?(changeset.changes, :patient_id)
    end

    test "rejects a missing encrypted_body on update" do
      observation = %ClinicianObservation{
        encrypted_body: <<1, 2, 3>>,
        patient_id: Ecto.UUID.generate(),
        professional_id: Ecto.UUID.generate(),
        target_behavior_id: Ecto.UUID.generate()
      }

      changeset = ClinicianObservation.update_changeset(observation, %{encrypted_body: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_body
    end
  end
end
