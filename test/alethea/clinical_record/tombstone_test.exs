defmodule Alethea.ClinicalRecord.TombstoneTest do
  @moduledoc """
  RED-phase specs for `Alethea.ClinicalRecord.Tombstone`
  (sdd/clinical-record-retention, GitHub #197, Phase 1/Slice A, task 1.6):
  `for_resource/2` lookup, content-free construction, unique on
  `{resource_type, resource_id}` (design (b)).
  """
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord.Tombstone

  @password "supersecret12"

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  describe "for_resource/2" do
    test "returns nil when no tombstone exists for the resource" do
      assert Tombstone.for_resource("clinician_observation", Ecto.UUID.generate()) == nil
    end

    test "returns the persisted tombstone for an exact resource_type/resource_id match", %{
      professional: professional,
      patient: patient
    } do
      resource_id = Ecto.UUID.generate()

      assert {:ok, tombstone} =
               %Tombstone{}
               |> Tombstone.changeset(%{
                 resource_type: "clinician_observation",
                 resource_id: resource_id,
                 patient_id: patient.id,
                 deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 deleted_by_id: professional.id,
                 trigger: "manual"
               })
               |> Repo.insert()

      assert found = Tombstone.for_resource("clinician_observation", resource_id)
      assert found.id == tombstone.id
      assert found.trigger == "manual"
    end

    test "a different resource_type with the same resource_id does not match (triangulation)", %{
      professional: professional,
      patient: patient
    } do
      resource_id = Ecto.UUID.generate()

      {:ok, _tombstone} =
        %Tombstone{}
        |> Tombstone.changeset(%{
          resource_type: "target_behavior",
          resource_id: resource_id,
          patient_id: patient.id,
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          deleted_by_id: professional.id,
          trigger: "sweep"
        })
        |> Repo.insert()

      assert Tombstone.for_resource("clinician_observation", resource_id) == nil
    end
  end

  describe "content-free, closed-vocabulary construction" do
    test "rejects a resource_type outside the six existing ClinicalRecord tables", %{
      patient: patient
    } do
      changeset =
        Tombstone.changeset(%Tombstone{}, %{
          resource_type: "message",
          resource_id: Ecto.UUID.generate(),
          patient_id: patient.id,
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          trigger: "manual"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).resource_type
    end

    test "rejects a trigger outside {sweep, manual}", %{patient: patient} do
      changeset =
        Tombstone.changeset(%Tombstone{}, %{
          resource_type: "target_behavior",
          resource_id: Ecto.UUID.generate(),
          patient_id: patient.id,
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          trigger: "batch"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).trigger
    end
  end

  describe "unique index on {resource_type, resource_id} (design (b))" do
    test "a second tombstone for the same resource_type/resource_id is rejected", %{
      professional: professional,
      patient: patient
    } do
      resource_id = Ecto.UUID.generate()

      attrs = %{
        resource_type: "clinician_observation",
        resource_id: resource_id,
        patient_id: patient.id,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        deleted_by_id: professional.id,
        trigger: "manual"
      }

      assert {:ok, _first} = %Tombstone{} |> Tombstone.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} = %Tombstone{} |> Tombstone.changeset(attrs) |> Repo.insert()
      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).resource_type
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "tombstone-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Tombstone"
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
