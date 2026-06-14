defmodule Alethea.Foundation.AccountsTest do
  use Alethea.DataCase, async: true

  alias Alethea.Foundation.Accounts

  describe "register_professional/1" do
    test "delegates to the Professional schema and returns a persisted row" do
      attrs = %{
        email: "ctx-pro-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret12",
        full_name: "Ctx Pro"
      }

      assert {:ok, %Alethea.Foundation.Accounts.Professional{} = pro} =
               Accounts.register_professional(attrs)

      assert pro.email == attrs.email
      assert is_binary(pro.password_hash)
    end
  end

  describe "create_patient/2 + update_patient/2" do
    test "delegates create_patient/2 to the Patient schema and update_patient/2 mutates" do
      pro = Alethea.FoundationTestHelper.professional_fixture()

      assert {:ok, %Alethea.Foundation.Accounts.Patient{} = patient} =
               Accounts.create_patient(pro, %{alias: "Ctx Pat"})

      assert patient.professional_id == pro.id

      assert {:ok, %Alethea.Foundation.Accounts.Patient{} = updated} =
               Accounts.update_patient(patient, %{status: "archived"})

      assert updated.status == "archived"
    end
  end

  describe "register_admin/1" do
    test "delegates to the Admin schema and returns a persisted row" do
      attrs = %{
        email: "ctx-admin-#{System.unique_integer([:positive])}@alethea.app",
        password: "supersecret12",
        role: "billing"
      }

      assert {:ok, %Alethea.Foundation.Accounts.Admin{} = admin} =
               Accounts.register_admin(attrs)

      assert admin.role == "billing"
    end
  end

  describe "public API surface" do
    test "exports the four canonical functions" do
      exported = Accounts.__info__(:functions)

      assert {:register_professional, 1} in exported
      assert {:register_admin, 1} in exported
      assert {:create_patient, 2} in exported
      assert {:update_patient, 2} in exported
    end
  end
end
