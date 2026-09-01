defmodule Alethea.ClinicalRecord.FunctionalAnalysisDraftTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.FunctionalAnalysisDraft`
  (sdd/alethea/issue-195-clinical-review-workbench, PR1b task 2.5).

  Single row per `target_behavior_id` (design A7/D4) — this test file
  covers the schema/changeset contract; the unique-index round-trip
  (constraint violation on a second insert) is covered at the migration
  level (task 2.6/DB test).
  """
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.FunctionalAnalysisDraft

  @valid_attrs %{
    encrypted_body: <<1, 2, 3>>,
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate(),
    target_behavior_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields" do
      changeset = FunctionalAnalysisDraft.changeset(%FunctionalAnalysisDraft{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :encrypted_body) == <<1, 2, 3>>
      assert get_change(changeset, :patient_id) == @valid_attrs.patient_id
      assert get_change(changeset, :professional_id) == @valid_attrs.professional_id
      assert get_change(changeset, :target_behavior_id) == @valid_attrs.target_behavior_id
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects a missing encrypted_body" do
      changeset =
        FunctionalAnalysisDraft.changeset(
          %FunctionalAnalysisDraft{},
          Map.delete(@valid_attrs, :encrypted_body)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_body
    end

    test "rejects a missing patient_id" do
      changeset =
        FunctionalAnalysisDraft.changeset(
          %FunctionalAnalysisDraft{},
          Map.delete(@valid_attrs, :patient_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "rejects a missing professional_id" do
      changeset =
        FunctionalAnalysisDraft.changeset(
          %FunctionalAnalysisDraft{},
          Map.delete(@valid_attrs, :professional_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).professional_id
    end

    test "rejects a missing target_behavior_id" do
      changeset =
        FunctionalAnalysisDraft.changeset(
          %FunctionalAnalysisDraft{},
          Map.delete(@valid_attrs, :target_behavior_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_behavior_id
    end
  end

  describe "no delete function exists (design D5 — discard is status-only elsewhere)" do
    test "the module exports no delete/1-style function" do
      refute function_exported?(FunctionalAnalysisDraft, :delete_changeset, 1)
      refute function_exported?(FunctionalAnalysisDraft, :delete_changeset, 2)
    end
  end

  describe "database-level single-row-per-target_behavior (task 2.6)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, "Salir a caminar")

      %{professional: professional, patient: patient, target_behavior: target_behavior}
    end

    test "a second insert for the same target_behavior_id violates the unique index", %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      attrs = %{
        encrypted_body: <<1, 2, 3>>,
        patient_id: patient.id,
        professional_id: professional.id,
        target_behavior_id: target_behavior.id
      }

      assert {:ok, _draft} =
               %FunctionalAnalysisDraft{}
               |> FunctionalAnalysisDraft.changeset(attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               %FunctionalAnalysisDraft{}
               |> FunctionalAnalysisDraft.changeset(attrs)
               |> Repo.insert()

      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).target_behavior_id
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "functional-analysis-draft-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Functional Analysis"
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
