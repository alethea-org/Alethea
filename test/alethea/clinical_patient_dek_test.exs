defmodule Alethea.ClinicalPatientDekTest do
  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical

  setup do
    professional = legacy_professional_fixture()
    patient = legacy_patient_fixture(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, expected_dek} = Accounts.load_patient_dek(patient, kek)
    %{professional: professional, patient: patient, expected_dek: expected_dek}
  end

  defp decrypt_reasons(patient) do
    AuditLog
    |> where([a], a.resource_id == ^patient.id and a.action == "PII_DECRYPT")
    |> Repo.all()
    |> Enum.map(& &1.details["reason"])
  end

  test "patient_dek/1 audits the default clinical_context_loading reason", ctx do
    assert {:ok, dek} = Clinical.patient_dek(ctx.patient)
    assert dek == ctx.expected_dek
    assert decrypt_reasons(ctx.patient) == ["clinical_context_loading"]
  end

  test "patient_dek/2 audits the given reason and returns the same DEK", ctx do
    assert {:ok, dek} = Clinical.patient_dek(ctx.patient, "running_summary_loading")
    assert dek == ctx.expected_dek
    assert decrypt_reasons(ctx.patient) == ["running_summary_loading"]
  end

  test "each call writes exactly one PII_DECRYPT row with its own reason", ctx do
    assert {:ok, _} = Clinical.patient_dek(ctx.patient)
    assert {:ok, _} = Clinical.patient_dek(ctx.patient, "running_summary_generation")

    assert Enum.sort(decrypt_reasons(ctx.patient)) ==
             ["clinical_context_loading", "running_summary_generation"]
  end

  test "patient_dek/2 rejects a non-binary reason", ctx do
    assert_raise FunctionClauseError, fn -> Clinical.patient_dek(ctx.patient, :oops) end
  end
end
