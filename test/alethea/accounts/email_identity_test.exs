defmodule Alethea.Accounts.EmailIdentityTest do
  @moduledoc """
  S3 (security-audit-run-1): a professional's email is a canonical
  identity. It is trimmed and downcased before storage and lookup, so
  `ADMIN@example.org` and `admin@example.org` are the same account and
  a case variant can never register a second, privileged-looking row.
  """

  use Alethea.DataCase, async: false

  alias Alethea.Accounts
  alias Alethea.Accounts.{Admin, AdmissionPolicy, Professional}

  @password "supersecret12"

  setup do
    initial_admins = Application.get_env(:alethea, :admin_emails)
    initial_restricted = Application.get_env(:alethea, :demo_restricted_access)
    initial_allowed = Application.get_env(:alethea, :demo_allowed_emails)

    on_exit(fn ->
      restore_env(:admin_emails, initial_admins)
      restore_env(:demo_restricted_access, initial_restricted)
      restore_env(:demo_allowed_emails, initial_allowed)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:alethea, key)
  defp restore_env(key, value), do: Application.put_env(:alethea, key, value)

  defp create(email) do
    Accounts.create_professional(%{email: email, password: @password, full_name: "Dr. Canon"})
  end

  describe "Professional.changeset/2 canonical email" do
    test "stores a trimmed, lowercased email" do
      assert {:ok, professional} = create("  Dr.Canon@Example.ORG ")
      assert professional.email == "dr.canon@example.org"
      assert Repo.get!(Professional, professional.id).email == "dr.canon@example.org"
    end

    test "normalize_email/1 trims and downcases" do
      assert Professional.normalize_email("  ADMIN@Example.org\n") == "admin@example.org"
    end
  end

  describe "case-insensitive uniqueness" do
    test "registering ADMIN@example.org when admin@example.org exists returns the unique-email error and creates no row" do
      assert {:ok, _admin} = create("admin@example.org")
      count_before = Repo.aggregate(Professional, :count)

      assert {:error, changeset} = create("ADMIN@example.org")
      assert {"has already been taken", _} = changeset.errors[:email]
      assert Repo.aggregate(Professional, :count) == count_before
    end
  end

  describe "lookup and login" do
    test "get_professional_by_email/1 finds the account regardless of casing and whitespace" do
      assert {:ok, professional} = create("lookup@example.org")
      assert %Professional{id: id} = Accounts.get_professional_by_email(" LookUp@Example.ORG ")
      assert id == professional.id
    end

    test "authenticate_professional/2 authenticates the same account with any casing" do
      assert {:ok, professional} = create("login@example.org")

      assert {:ok, %Professional{id: id}} =
               Accounts.authenticate_professional("  LOGIN@Example.Org ", @password)

      assert id == professional.id

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_professional("LOGIN@example.org", "wrong-password1")
    end
  end

  describe "existing role checks keep their normalization" do
    test "Admin.admin?/1 still matches a listed email case-insensitively" do
      Application.put_env(:alethea, :admin_emails, ["Boss@Example.org"])

      assert Admin.admin?(%{email: " boss@EXAMPLE.org "})
      refute Admin.admin?(%{email: "other@example.org"})
      refute Admin.admin?(nil)
    end

    test "AdmissionPolicy.allowed_email?/1 still matches a listed email case-insensitively" do
      Application.put_env(:alethea, :demo_restricted_access, true)
      Application.put_env(:alethea, :demo_allowed_emails, [" Invited@Example.org "])

      assert AdmissionPolicy.allowed_email?("INVITED@example.org ")
      refute AdmissionPolicy.allowed_email?("other@example.org")
      refute AdmissionPolicy.allowed_email?(nil)
    end
  end
end
