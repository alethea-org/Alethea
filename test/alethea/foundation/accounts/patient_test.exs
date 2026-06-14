defmodule Alethea.Foundation.Accounts.PatientTest do
  use Alethea.DataCase, async: true

  alias Alethea.Foundation.Accounts.Professional
  alias Alethea.Foundation.Accounts.Patient

  @valid_password "supersecret12"

  defp create_professional do
    {:ok, professional} =
      Professional.register_professional(%{
        email: "pro-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        full_name: "Test Pro"
      })

    professional
  end

  describe "create_patient/2 — happy path" do
    test "creates a patient bound to the professional with default status 'active'" do
      professional = create_professional()

      assert {:ok, %Patient{} = patient} = Patient.create_patient(professional, %{alias: "JP"})

      assert patient.alias == "JP"
      assert patient.professional_id == professional.id
      assert patient.status == "active"
      assert is_binary(patient.id)
    end

    test "the professional_id is set programmatically and is not in the cast list" do
      professional = create_professional()

      assert {:ok, %Patient{} = patient} =
               Patient.create_patient(professional, %{
                 alias: "JP",
                 professional_id: "attacker-uuid"
               })

      assert patient.professional_id == professional.id
    end
  end

  describe "create_patient/2 — validation" do
    test "rejects a nil professional" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Patient.create_patient(nil, %{alias: "JP"})

      assert %{professional_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "update_patient/2 — status enum" do
    test "rejects a status outside the canonical set" do
      professional = create_professional()
      {:ok, patient} = Patient.create_patient(professional, %{alias: "JP"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Patient.update_patient(patient, %{status: "frozen"})

      assert %{status: [_ | _]} = errors_on(changeset)
    end

    test "accepts each canonical status" do
      professional = create_professional()
      {:ok, patient} = Patient.create_patient(professional, %{alias: "JP"})

      for status <- ["active", "archived", "deleted"] do
        assert {:ok, %Patient{} = updated} = Patient.update_patient(patient, %{status: status})
        assert updated.status == status
      end
    end
  end
end
