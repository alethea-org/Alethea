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

  alias Alethea.Foundation.Accounts.{Admin, BotConfig, Patient, Professional}

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

  @doc """
  Creates and persists a legacy (`Alethea.Accounts`) professional —
  the tenant the foundation `Professional` bridges to via the email
  bridge (`invite_patient_to_telegram/2`). Accepts an optional map of
  overrides for `:email`, `:password`, `:full_name`, etc.

  ## Defaults

  - Email: `legacy-pro-<n>@test.local`
  - Password: `supersecret12` (12 characters, passes the legacy
    `validate_length(:password, min: 12)`)
  - Full name: `"Legacy Pro <n>"`
  """
  def legacy_professional_fixture(attrs \\ %{}) do
    base = %{
      email: "legacy-pro-#{System.unique_integer([:positive])}@test.local",
      password: "supersecret12",
      full_name: "Legacy Pro #{System.unique_integer([:positive])}"
    }

    merged = Map.merge(base, attrs)

    {:ok, professional} = Alethea.Accounts.create_professional(merged)
    professional
  end

  @doc """
  Creates and persists a legacy (`Alethea.Accounts`) patient bound to
  the given legacy professional, wrapping a fresh DEK with the
  professional's KEK (the same path `create_patient/2` uses in
  production). Accepts an optional map of overrides for `:alias`, etc.

  ## Defaults

  - Alias: `"Legacy Pat <n>"`
  """
  def legacy_patient_fixture(professional, attrs \\ %{}) do
    base = %{
      alias: "Legacy Pat #{System.unique_integer([:positive])}",
      professional_id: professional.id
    }

    merged = Map.merge(base, attrs)

    {:ok, kek} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} = Alethea.Accounts.create_patient(merged, kek)
    patient
  end

  @doc """
  Upserts a `BotConfig` row for the `"test"` env so `BotConfig.for_env/1`
  resolves during tests. Accepts an optional map of overrides for
  `:env`, `:bot_token`, `:secret_token`, `:bot_username`.
  """
  def bot_config_fixture(attrs \\ %{}) do
    base = %{
      env: "test",
      bot_token: "123456:TEST-bot-token-fixture",
      secret_token: "test-secret-token-fixture",
      bot_username: "fixture_bot"
    }

    merged = Map.merge(base, attrs)

    {:ok, bot_config} = BotConfig.upsert(merged)
    bot_config
  end
end
