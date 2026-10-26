defmodule Alethea.Accounts.AdmissionPolicyTest do
  use ExUnit.Case, async: false

  alias Alethea.Accounts.AdmissionPolicy

  setup do
    initial_restricted = Application.get_env(:alethea, :demo_restricted_access)
    initial_allowed = Application.get_env(:alethea, :demo_allowed_emails)

    on_exit(fn ->
      if initial_restricted == nil do
        Application.delete_env(:alethea, :demo_restricted_access)
      else
        Application.put_env(:alethea, :demo_restricted_access, initial_restricted)
      end

      if initial_allowed == nil do
        Application.delete_env(:alethea, :demo_allowed_emails)
      else
        Application.put_env(:alethea, :demo_allowed_emails, initial_allowed)
      end
    end)

    :ok
  end

  describe "restricted?/0" do
    test "returns false when demo_restricted_access is unset" do
      Application.delete_env(:alethea, :demo_restricted_access)
      refute AdmissionPolicy.restricted?()
    end

    test "returns false when demo_restricted_access is false" do
      Application.put_env(:alethea, :demo_restricted_access, false)
      refute AdmissionPolicy.restricted?()
    end

    test "returns true only when demo_restricted_access is true" do
      Application.put_env(:alethea, :demo_restricted_access, true)
      assert AdmissionPolicy.restricted?()

      Application.put_env(:alethea, :demo_restricted_access, "true")
      refute AdmissionPolicy.restricted?()
    end
  end

  describe "allowed_email?/1" do
    test "when unrestricted, allows any email, nil, or case variants" do
      Application.put_env(:alethea, :demo_restricted_access, false)

      assert AdmissionPolicy.allowed_email?("anyone@example.com")
      assert AdmissionPolicy.allowed_email?("USER@DOMAIN.ORG")
      assert AdmissionPolicy.allowed_email?(nil)
      assert AdmissionPolicy.allowed_email?("")
    end

    test "when restricted with an allowlist, allows listed emails case-insensitively and rejects others" do
      Application.put_env(:alethea, :demo_restricted_access, true)

      Application.put_env(:alethea, :demo_allowed_emails, [
        "user@example.com",
        "prof@university.edu"
      ])

      assert AdmissionPolicy.allowed_email?("user@example.com")
      assert AdmissionPolicy.allowed_email?("User@Example.COM")
      assert AdmissionPolicy.allowed_email?(" PROF@university.edu ")

      refute AdmissionPolicy.allowed_email?("intruder@example.com")
      refute AdmissionPolicy.allowed_email?(nil)
      refute AdmissionPolicy.allowed_email?("")
    end

    test "when restricted and allowlist is empty or missing, rejects all (fail closed)" do
      Application.put_env(:alethea, :demo_restricted_access, true)

      Application.put_env(:alethea, :demo_allowed_emails, [])
      refute AdmissionPolicy.allowed_email?("user@example.com")
      refute AdmissionPolicy.allowed_email?(nil)

      Application.delete_env(:alethea, :demo_allowed_emails)
      refute AdmissionPolicy.allowed_email?("user@example.com")
      refute AdmissionPolicy.allowed_email?(nil)
    end
  end
end
