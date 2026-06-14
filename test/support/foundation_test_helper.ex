defmodule Alethea.FoundationTestHelper do
  @moduledoc """
  Test fixtures for the `Alethea.Foundation.*` namespace.

  Provides `professional_fixture/1` and `patient_fixture/2` so tests
  in `test/alethea/foundation/**/*_test.exs` can spin up real
  rows against the sandboxed test DB without duplicating setup
  boilerplate.

  ## Usage

      use Alethea.DataCase, async: true
      import Alethea.FoundationTestHelper

      test "something" do
        professional = professional_fixture()
        patient = patient_fixture(professional, %{alias: "JP"})
        ...
      end

  ## Defaults

  - Email: `pro-<n>@example.com` / `pat-<n>@example.com` where `<n>` is
    `System.unique_integer([:positive])` at call time
  - Password: 12+ characters (passes the spec's `validate_length(:password, min: 12)`)
  - Full name: `"Pro <n>"`
  - Alias: `"Pat <n>"`
  - Status: `"active"`
  """

  alias Alethea.Foundation.Accounts.{Admin, Patient, Professional}

  @default_password "fixturepass1234"

  @doc """
  Creates and persists a foundation Professional. Accepts an optional
  map of overrides for `:email`, `:password`, `:full_name`, etc.
  """
  def professional_fixture(attrs \\ %{}) do
    base = %{
      email: "pro-#{System.unique_integer([:positive])}@example.com",
      password: @default_password,
      full_name: "Pro #{System.unique_integer([:positive])}"
    }

    merged = Map.merge(base, attrs)

    {:ok, professional} = Professional.register_professional(merged)
    professional
  end

  @doc """
  Creates and persists a foundation Patient bound to the given
  professional. Accepts an optional map of overrides for `:alias`,
  `:status`, etc.
  """
  def patient_fixture(professional, attrs \\ %{}) do
    base = %{
      alias: "Pat #{System.unique_integer([:positive])}"
    }

    merged = Map.merge(base, attrs)

    {:ok, patient} = Patient.create_patient(professional, merged)
    patient
  end

  @doc """
  Creates and persists a foundation Admin. Accepts an optional map of
  overrides for `:email`, `:password`, `:role`, etc.
  """
  def admin_fixture(attrs \\ %{}) do
    base = %{
      email: "admin-#{System.unique_integer([:positive])}@alethea.app",
      password: @default_password,
      role: "superadmin"
    }

    merged = Map.merge(base, attrs)

    {:ok, admin} = Admin.register_admin(merged)
    admin
  end
end
