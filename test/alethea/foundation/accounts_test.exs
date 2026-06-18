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
    test "exports the five canonical functions" do
      exported = Accounts.__info__(:functions)

      assert {:register_professional, 1} in exported
      assert {:register_admin, 1} in exported
      assert {:create_patient, 2} in exported
      assert {:update_patient, 2} in exported
      assert {:lookup_patient_by_chat_hash, 1} in exported
    end
  end

  describe "lookup_patient_by_chat_hash/1 — REQ-C2-lookup-by-hash" do
    test "returns {:ok, patient} for a patient bound to a known hash" do
      pro = Alethea.FoundationTestHelper.professional_fixture()
      hash = valid_hash_for(42)
      {:ok, patient} = Accounts.create_patient(pro, %{alias: "Bound", telegram_chat_id_hash: hash})

      assert {:ok, %Alethea.Foundation.Accounts.Patient{id: id}} =
               Accounts.lookup_patient_by_chat_hash(hash)

      assert id == patient.id
    end

    test "returns :not_found for an unknown hash" do
      assert Accounts.lookup_patient_by_chat_hash(unbound_hash()) == :not_found
    end

    test "returns :not_found for a raw chat_id (rejected at the API boundary)" do
      # REQ-C2-lookup-by-hash: the function accepts only the 64-char
      # hex hash form. A raw chat_id integer-as-string (9 chars) is
      # not a valid hash, so the function must not return a false
      # positive by hashing on the caller side.
      assert Accounts.lookup_patient_by_chat_hash("123456789") == :not_found
    end

    test "returns :not_found for non-hex garbage (also not a 64-char hash)" do
      # 64 chars but not lowercase hex
      assert Accounts.lookup_patient_by_chat_hash(String.duplicate("Z", 64)) == :not_found
    end
  end

  describe "lookup_patient_by_chat_hash/1 — REQ-C2-partial-unique-index" do
    test "two patients bound to the same hash: the second insert fails at the DB layer" do
      pro = Alethea.FoundationTestHelper.professional_fixture()
      hash = valid_hash_for(99)

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "First", telegram_chat_id_hash: hash})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_patient(pro, %{alias: "Second", telegram_chat_id_hash: hash})
    end

    test "multiple patients with NULL telegram_chat_id_hash coexist" do
      pro = Alethea.FoundationTestHelper.professional_fixture()

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "P1"})

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "P2"})

      assert {:ok, %Alethea.Foundation.Accounts.Patient{}} =
               Accounts.create_patient(pro, %{alias: "P3"})
    end
  end

  # --- helpers ---

  # A deterministic 64-char lowercase hex hash, the only input shape
  # `lookup_patient_by_chat_hash/1` is allowed to accept.
  defp valid_hash_for(seed) do
    :crypto.mac(:hmac, :sha256, "pepper-v1-32-bytes-min-len-padding-pad", "chat-#{seed}")
    |> Base.encode16(case: :lower)
  end

  # A hash that no patient row is bound to in the test DB.
  defp unbound_hash, do: valid_hash_for("unbound-#{System.unique_integer([:positive])}")
end
