defmodule Alethea.Foundation.Accounts.PatientAuthCodeConcurrencyTest do
  @moduledoc """
  Real concurrent regression test for the rate-limit TOCTOU fix in
  `Alethea.Foundation.Accounts.PatientAuthCode`.

  Split into its own `async: false` module (mirroring
  `BotConfigTest`'s F-07 concurrency guard) rather than added to
  `PatientAuthCodeTest` (which is `async: true`) so this one test's
  need for a shared sandbox connection doesn't force the rest of that
  file's many tests to run serially.
  """

  use Alethea.DataCase, async: false

  import Alethea.FoundationTestHelper

  alias Alethea.Foundation.Accounts.PatientAuthCode
  alias Alethea.Repo

  # Judgment Day Round 3 (R3-001): the sequential regression tests in
  # `PatientAuthCodeTest` prove the `FOR UPDATE` lock exists (SQL
  # string) and that single-call behavior is unchanged, but they never
  # actually exercise concurrency. This test fires N concurrent
  # `verify_patient_auth_code/3` calls against the SAME row and IP and
  # asserts `attempt_count == N` — before the fix
  # (`apply_rate_limit_increment/3` re-fetching with `FOR UPDATE`
  # inside a transaction), this would race: two callers could both
  # read the same stale `attempt_count` and one write would be lost,
  # landing at N-1 (or lower) instead of N.
  test "concurrent verify_patient_auth_code/3 calls on the same row/IP don't lose updates" do
    professional = professional_fixture()
    patient = patient_fixture(professional)
    {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

    concurrency = 10

    1..concurrency
    |> Enum.map(fn _ ->
      Task.async(fn ->
        PatientAuthCode.verify_patient_auth_code(auth_code.code, "5.5.5.5", kind: "deep_link")
      end)
    end)
    |> Task.await_many(5_000)

    reloaded = Repo.get!(PatientAuthCode, auth_code.id)
    assert reloaded.attempt_count == concurrency
    assert reloaded.last_attempt_ip == "5.5.5.5"
  end

  # Judgment Day Round 1 (CRITICAL): consume_patient_auth_code/3 fetches
  # the row with `FOR UPDATE` so a concurrent second consume of the
  # SAME code serializes instead of racing to a double-bind. The
  # sequential test in `PatientAuthCodeTest` only proves the query
  # compiles to `FOR UPDATE` SQL; this fires real concurrent consumers
  # and asserts exactly one wins.
  test "concurrent consume_patient_auth_code/3 calls for the same code bind exactly once" do
    professional = professional_fixture()
    patient = patient_fixture(professional)
    {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

    concurrency = 10

    results =
      1..concurrency
      |> Enum.map(fn i ->
        Task.async(fn ->
          hash = String.duplicate("#{rem(i, 10)}", 64)
          PatientAuthCode.consume_patient_auth_code(auth_code.code, hash, kind: "deep_link")
        end)
      end)
      |> Task.await_many(5_000)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    already_used = Enum.count(results, &match?({:error, :already_used}, &1))

    assert successes == 1
    assert already_used == concurrency - 1

    reloaded_code = Repo.get!(PatientAuthCode, auth_code.id)
    assert %DateTime{} = reloaded_code.used_at
  end
end
