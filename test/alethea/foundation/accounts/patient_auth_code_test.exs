defmodule Alethea.Foundation.Accounts.PatientAuthCodeTest do
  @moduledoc """
  Tests for `Alethea.Foundation.Accounts.PatientAuthCode` (C-4 full;
  PR #4).

  TASK-4-1 covers the persistence half of `REQ-C4-mint-deep-link-token`
  (`create_patient_auth_code/2`) and the schema/migration shape.
  TASK-4-2 extends this file with `verify_patient_auth_code/3` and
  `consume_patient_auth_code/2` (a later commit in the same PR).
  """

  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  alias Alethea.Foundation.Accounts.PatientAuthCode
  alias Alethea.Repo

  # ----------------------------------------------------------------
  # TASK-4-1 — create_patient_auth_code/2 (REQ-C4-mint-deep-link-token,
  # persistence half)
  # ----------------------------------------------------------------

  describe "create_patient_auth_code/2 — deep_link" do
    setup do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      %{patient: patient}
    end

    test "fresh token is mintable", %{patient: patient} do
      before_count = Repo.aggregate(PatientAuthCode, :count)

      assert {:ok, auth_code} =
               PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      assert Repo.aggregate(PatientAuthCode, :count) == before_count + 1
      assert auth_code.kind == "deep_link"
      assert auth_code.patient_id == patient.id
      assert auth_code.used_at == nil
      assert auth_code.attempt_count == 0
      assert auth_code.last_attempt_ip == nil

      # 32 raw bytes URL-safe base64 (no padding) is exactly 43 chars.
      assert byte_size(auth_code.code) == 43
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, auth_code.code)

      # expires_at is ~600 seconds after "now" (computed independently
      # of `inserted_at` to avoid a flaky assertion across a second
      # boundary between the two `DateTime.utc_now/0` calls).
      delta = DateTime.diff(auth_code.expires_at, DateTime.utc_now(), :second)
      assert_in_delta delta, 600, 2
    end

    test "two mints for the same patient are independently unique", %{patient: patient} do
      {:ok, first} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")
      {:ok, second} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      assert first.code != second.code
    end
  end

  describe "create_patient_auth_code/2 — six_digit" do
    setup do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      %{patient: patient}
    end

    test "mints a 6-digit numeric code", %{patient: patient} do
      assert {:ok, auth_code} =
               PatientAuthCode.create_patient_auth_code(patient.id, kind: "six_digit")

      assert auth_code.kind == "six_digit"
      assert String.length(auth_code.code) == 6
      assert Regex.match?(~r/^[0-9]{6}$/, auth_code.code)
    end
  end
end
