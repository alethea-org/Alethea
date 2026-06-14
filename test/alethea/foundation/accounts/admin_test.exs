defmodule Alethea.Foundation.Accounts.AdminTest do
  use Alethea.DataCase, async: true

  alias Alethea.Foundation.Accounts.Admin
  alias Alethea.Foundation.Accounts.Professional

  @valid_password "supersecret12"

  describe "register_admin/1 — independent signup" do
    test "creates an admin without creating a professional" do
      attrs = %{
        email: "ops-#{System.unique_integer([:positive])}@alethea.app",
        password: @valid_password,
        role: "superadmin"
      }

      assert {:ok, %Admin{} = admin} = Admin.register_admin(attrs)

      assert admin.email == attrs.email
      assert admin.role == "superadmin"
      assert is_binary(admin.password_hash)
      refute admin.password_hash == @valid_password
      assert is_binary(admin.id)

      # Confirm no professional was created for the same email
      assert_raise Ecto.NoResultsError, fn ->
        Alethea.Repo.get_by!(Professional, email: attrs.email)
      end
    end
  end

  describe "register_admin/1 — role validation" do
    test "rejects a role outside the canonical set" do
      attrs = %{
        email: "bad-#{System.unique_integer([:positive])}@alethea.app",
        password: @valid_password,
        role: "godmode"
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Admin.register_admin(attrs)

      assert %{role: [_ | _]} = errors_on(changeset)
    end

    test "accepts each canonical role" do
      for role <- ["superadmin", "support", "billing"] do
        attrs = %{
          email: "admin-#{System.unique_integer([:positive])}@alethea.app",
          password: @valid_password,
          role: role
        }

        assert {:ok, %Admin{} = admin} = Admin.register_admin(attrs)
        assert admin.role == role
      end
    end
  end
end
