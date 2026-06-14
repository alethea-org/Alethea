defmodule Alethea.FoundationTestHelperTest do
  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  describe "professional_fixture/1" do
    test "returns a persisted Professional with email, password_hash, and id populated" do
      professional = professional_fixture()
      assert %Alethea.Foundation.Accounts.Professional{} = professional
      assert is_binary(professional.email)
      assert professional.email =~ "@"
      assert is_binary(professional.password_hash)
      assert is_binary(professional.id)
    end

    test "accepts overrides for email, full_name, and password" do
      pro =
        professional_fixture(%{
          email: "override@example.com",
          full_name: "Override Name",
          password: "overridenpw12"
        })

      assert pro.email == "override@example.com"
      assert pro.full_name == "Override Name"
      assert Pbkdf2.verify_pass("overridenpw12", pro.password_hash)
    end
  end

  describe "patient_fixture/2" do
    test "returns a persisted Patient bound to the given professional" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      assert %Alethea.Foundation.Accounts.Patient{} = patient
      assert patient.professional_id == professional.id
      assert patient.status == "active"
      assert is_binary(patient.alias)
    end

    test "accepts overrides for alias and status" do
      professional = professional_fixture()
      patient = patient_fixture(professional, %{alias: "My Alias", status: "archived"})
      assert patient.alias == "My Alias"
      assert patient.status == "archived"
    end
  end
end
