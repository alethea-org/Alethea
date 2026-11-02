defmodule Alethea.TriggersFixtures do
  @moduledoc """
  Test helpers for creating Triggers-related entities.
  """

  alias Alethea.Accounts
  alias Alethea.Foundation.Accounts, as: FoundationAccounts

  def unique_int, do: System.unique_integer([:positive])

  def fixture_professional_and_patient(attrs \\ %{}) do
    pro_int = unique_int()

    {:ok, professional} =
      Accounts.create_professional(%{
        email: "pro-#{pro_int}@test.local",
        password: "supersecret123",
        full_name: "Dr. Test #{pro_int}"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    patient_int = unique_int()

    patient_attrs =
      Map.merge(
        %{
          "alias" => "Paciente #{patient_int}",
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        attrs
      )

    {:ok, patient} = Accounts.create_patient(patient_attrs, kek)

    {:ok, foundation_pro} =
      FoundationAccounts.find_or_provision_foundation_professional(professional)

    {:ok, foundation_patient} =
      FoundationAccounts.create_patient(foundation_pro, %{
        alias: patient.alias,
        legacy_patient_id: patient.id
      })

    %{
      professional: professional,
      patient: patient,
      kek: kek,
      foundation_pro: foundation_pro,
      foundation_patient: foundation_patient
    }
  end
end
