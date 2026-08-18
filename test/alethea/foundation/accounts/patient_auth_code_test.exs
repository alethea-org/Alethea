defmodule Alethea.Foundation.Accounts.PatientAuthCodeTest do
  @moduledoc """
  Tests for `Alethea.Foundation.Accounts.PatientAuthCode` (C-4 full;
  PR #4).

  TASK-4-1 covers the persistence half of `REQ-C4-mint-deep-link-token`
  (`create_patient_auth_code/2`) and the schema/migration shape.
  TASK-4-2 extends this file with `verify_patient_auth_code/3` and
  `consume_patient_auth_code/3` (see the second `describe` block group
  below, added in the same PR).
  """

  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper
  import Ecto.Query

  alias Alethea.Foundation.Accounts.{Patient, PatientAuthCode}
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

  # ----------------------------------------------------------------
  # TASK-4-2 — verify_patient_auth_code/3 (REQ-C4-reject-expired-token,
  # REQ-C4-reject-already-used-token, REQ-C4-reject-rate-limited)
  # ----------------------------------------------------------------

  describe "verify_patient_auth_code/3" do
    setup do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")
      %{patient: patient, auth_code: auth_code}
    end

    test "fresh unexpired unused code returns :ok", %{auth_code: auth_code} do
      assert :ok =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.2.3.4",
                 kind: "deep_link"
               )
    end

    test "code past its TTL is expired and the row is not mutated", %{auth_code: auth_code} do
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      set_expires_at(auth_code, past)

      assert :expired =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.2.3.4",
                 kind: "deep_link"
               )

      reloaded = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded.attempt_count == 0
      assert reloaded.used_at == nil
      assert reloaded.last_attempt_ip == nil
    end

    test "code with at least one full second remaining is valid", %{
      auth_code: auth_code
    } do
      future = DateTime.utc_now() |> DateTime.add(2, :second) |> DateTime.truncate(:second)
      set_expires_at(auth_code, future)

      assert :ok =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.2.3.4",
                 kind: "deep_link"
               )
    end

    test "code at its TTL boundary is expired", %{auth_code: auth_code} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      set_expires_at(auth_code, now)

      assert :expired =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.2.3.4",
                 kind: "deep_link"
               )
    end

    test "consumed token is rejected on re-use as :already_used", %{auth_code: auth_code} do
      used_at = DateTime.utc_now() |> DateTime.truncate(:second)

      auth_code
      |> PatientAuthCode.changeset(%{used_at: used_at})
      |> Repo.update!()

      assert :already_used =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.2.3.4",
                 kind: "deep_link"
               )
    end

    test "5th attempt in the window from the same IP returns :rate_limited", %{
      auth_code: auth_code
    } do
      ip = "9.9.9.9"

      for _ <- 1..4 do
        assert :ok =
                 PatientAuthCode.verify_patient_auth_code(auth_code.code, ip, kind: "deep_link")
      end

      assert :rate_limited =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, ip, kind: "deep_link")

      reloaded = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded.attempt_count == 5
      assert reloaded.last_attempt_ip == ip
    end

    test "a 6th attempt keeps incrementing attempt_count even while blocked", %{
      auth_code: auth_code
    } do
      ip = "9.9.9.9"

      for _ <- 1..5 do
        PatientAuthCode.verify_patient_auth_code(auth_code.code, ip, kind: "deep_link")
      end

      assert :rate_limited =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, ip, kind: "deep_link")

      reloaded = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded.attempt_count == 6
    end

    test "5th attempt across a different IP is allowed (rate-limit is per-IP, not global)", %{
      auth_code: auth_code
    } do
      for _ <- 1..4 do
        PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.1.1.1", kind: "deep_link")
      end

      assert :ok =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "2.2.2.2",
                 kind: "deep_link"
               )
    end

    test "attempts older than 1h do not count (rolling window rolled off)", %{
      auth_code: auth_code
    } do
      for _ <- 1..4 do
        PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.1.1.1", kind: "deep_link")
      end

      two_hours_ago =
        DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

      from(a in PatientAuthCode, where: a.id == ^auth_code.id)
      |> Repo.update_all(set: [updated_at: two_hours_ago])

      assert :ok =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "1.1.1.1",
                 kind: "deep_link"
               )
    end

    test "an unknown code is treated the same as expired", %{} do
      assert :expired =
               PatientAuthCode.verify_patient_auth_code("does-not-exist", "1.2.3.4",
                 kind: "deep_link"
               )
    end

    test "a code minted as six_digit is not found under kind: deep_link", %{patient: patient} do
      {:ok, six_digit} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "six_digit")

      assert :expired =
               PatientAuthCode.verify_patient_auth_code(six_digit.code, "1.2.3.4",
                 kind: "deep_link"
               )
    end

    # Regression (CRITICAL fix): guessing a code that matches NO row
    # used to be completely untracked — an attacker could enumerate
    # the whole keyspace from one IP with zero throttling. Repeated
    # wrong guesses from the same IP must now trip the rate limit
    # without ever landing on a real code.
    test "guessing a nonexistent code repeatedly from the same IP eventually rate-limits", %{
      auth_code: auth_code
    } do
      ip = "6.6.6.6"

      results =
        for _ <- 1..5 do
          PatientAuthCode.verify_patient_auth_code("000000-does-not-exist", ip, kind: "deep_link")
        end

      assert Enum.all?(results, &(&1 in [:expired, :rate_limited]))
      assert List.last(results) == :rate_limited
      refute :ok in results

      # The real code was never touched by the guesser reaching :ok —
      # only its rate-limit tracking columns may have been used as the
      # borrowed stand-in row (see moduledoc "Guessing a code that
      # matches no row").
      reloaded = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded.used_at == nil
    end

    test "a wrong-code guess from a different IP is not blocked by another IP's guesses" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, _} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      for _ <- 1..4 do
        PatientAuthCode.verify_patient_auth_code("bad-guess", "7.7.7.7", kind: "deep_link")
      end

      assert :expired =
               PatientAuthCode.verify_patient_auth_code("bad-guess", "8.8.8.8", kind: "deep_link")
    end

    # Regression (WARNING fix, Round 2): the rate-limit read-then-write
    # used to read the auth-code struct fetched earlier (no lock) and
    # then `Repo.update()` unlocked — two concurrent requests against
    # the SAME row could both compute `new_count` from the same stale
    # `attempt_count`, losing an update and under-counting a
    # brute-force burst. `check_rate_limit/2` and
    # `check_unmatched_rate_limit/2` now share
    # `apply_rate_limit_increment/3`, which re-fetches the row via
    # `fetch_by_code_and_kind_for_update/3` (the SAME
    # `for_update_query/2` already proven to compile to `FOR UPDATE`
    # SQL below) inside a `Repo.transaction/1`, mirroring
    # `consume_patient_auth_code/3`'s existing lock. A log-capture
    # assertion was tried here but this app's test env pins
    # `config :logger, level: :warning` (config/test.exs), which
    # suppresses Ecto's `:debug`-level query logging before
    # `ExUnit.CaptureLog` ever sees it — so instead this asserts the
    # functional behavior the lock protects: the counter still
    # increments correctly across both paths (proving the refactor to
    # the locked fetch didn't change observable behavior), while the
    # "compiles to FOR UPDATE SQL" test below proves the query itself
    # is locked.
    test "check_rate_limit/2 (known code) still increments attempt_count after the locked refetch",
         %{auth_code: auth_code} do
      assert :ok =
               PatientAuthCode.verify_patient_auth_code(auth_code.code, "3.3.3.3",
                 kind: "deep_link"
               )

      reloaded = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded.attempt_count == 1
      assert reloaded.last_attempt_ip == "3.3.3.3"
    end

    # Same race shape, unmatched-code path — see moduledoc "Guessing a
    # code that matches no row". `check_unmatched_rate_limit/2` shares
    # `apply_rate_limit_increment/3` with `check_rate_limit/2`, so the
    # same lock must be exercised here too; the borrowed stand-in row
    # (the only live row of this `kind`) must still show the
    # incremented counter after the locked refetch.
    test "check_unmatched_rate_limit/2 (unmatched code) still increments the borrowed row's attempt_count",
         %{auth_code: auth_code} do
      assert :expired =
               PatientAuthCode.verify_patient_auth_code("000000-does-not-exist", "4.4.4.4",
                 kind: "deep_link"
               )

      reloaded = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded.attempt_count == 1
      assert reloaded.last_attempt_ip == "4.4.4.4"
    end
  end

  # ----------------------------------------------------------------
  # TASK-4-2 — consume_patient_auth_code/3 (REQ-C4-bind-chat-on-success,
  # REQ-C4-reject-chat-bound-to-other-patient)
  # ----------------------------------------------------------------

  describe "consume_patient_auth_code/3" do
    setup do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")
      %{patient: patient, auth_code: auth_code}
    end

    test "binds the patient's telegram_chat_id_hash and marks the code used", %{
      patient: patient,
      auth_code: auth_code
    } do
      hash = String.duplicate("a", 64)

      assert {:ok, bound_patient} =
               PatientAuthCode.consume_patient_auth_code(auth_code.code, hash, kind: "deep_link")

      assert bound_patient.id == patient.id
      assert bound_patient.telegram_chat_id_hash == hash

      reloaded_code = Repo.get!(PatientAuthCode, auth_code.id)
      assert %DateTime{} = reloaded_code.used_at
    end

    test "second consume attempt fails because the code is already used", %{
      auth_code: auth_code
    } do
      hash = String.duplicate("a", 64)

      {:ok, _} =
        PatientAuthCode.consume_patient_auth_code(auth_code.code, hash, kind: "deep_link")

      assert {:error, :already_used} =
               PatientAuthCode.consume_patient_auth_code(auth_code.code, hash, kind: "deep_link")
    end

    test "chat_id_hash already bound to a different patient is rejected", %{
      auth_code: auth_code_b
    } do
      professional = professional_fixture()
      patient_a = patient_fixture(professional)
      hash = String.duplicate("b", 64)
      {:ok, _} = Patient.update_patient(patient_a, %{telegram_chat_id_hash: hash})

      assert {:error, :chat_bound_to_other_patient} =
               PatientAuthCode.consume_patient_auth_code(auth_code_b.code, hash,
                 kind: "deep_link"
               )

      reloaded_a = Repo.get!(Patient, patient_a.id)
      assert reloaded_a.telegram_chat_id_hash == hash

      reloaded_code_b = Repo.get!(PatientAuthCode, auth_code_b.id)
      assert reloaded_code_b.used_at == nil
    end

    test "same patient rebinding their own chat is allowed", %{
      patient: patient,
      auth_code: auth_code
    } do
      h1 = String.duplicate("c", 64)
      {:ok, _} = Patient.update_patient(patient, %{telegram_chat_id_hash: h1})

      h2 = String.duplicate("d", 64)

      assert {:ok, rebound} =
               PatientAuthCode.consume_patient_auth_code(auth_code.code, h2, kind: "deep_link")

      assert rebound.telegram_chat_id_hash == h2
    end

    # Regression (CRITICAL fix): two rows sharing the identical `code`
    # value but different `kind`s used to reach `repo.get_by(__MODULE__,
    # code: code)` (no `kind` filter) and raise
    # `Ecto.MultipleResultsError`. Consuming the correctly-`kind`-scoped
    # one must succeed without crashing.
    test "a code collision across different kinds does not raise Ecto.MultipleResultsError", %{
      patient: patient,
      auth_code: deep_link_code
    } do
      shared_code = deep_link_code.code

      {:ok, six_digit_code} =
        %PatientAuthCode{}
        |> PatientAuthCode.changeset(%{
          patient_id: patient.id,
          code: shared_code,
          kind: "six_digit",
          expires_at:
            DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second),
          used_at: nil,
          attempt_count: 0,
          last_attempt_ip: nil
        })
        |> Repo.insert()

      assert shared_code == six_digit_code.code

      hash = String.duplicate("e", 64)

      assert {:ok, bound_patient} =
               PatientAuthCode.consume_patient_auth_code(shared_code, hash, kind: "deep_link")

      assert bound_patient.id == patient.id

      reloaded_deep_link = Repo.get!(PatientAuthCode, deep_link_code.id)
      assert %DateTime{} = reloaded_deep_link.used_at

      reloaded_six_digit = Repo.get!(PatientAuthCode, six_digit_code.id)
      assert reloaded_six_digit.used_at == nil
    end

    # Regression (CRITICAL fix): the auth-code row must be fetched with
    # a row-level lock so a concurrent second `consume_patient_auth_code/3`
    # for the SAME row serializes instead of racing to a double-bind.
    # This asserts the REAL production query builder
    # (`PatientAuthCode.for_update_query/2`, exposed `@doc false` for
    # exactly this) rather than an inline duplicate, so the test would
    # fail if the lock were ever removed from the actual function. A
    # true concurrent-process regression test for BOTH this lock and
    # the rate-limit lock (Round 3, R3-001) lives in
    # `PatientAuthCodeConcurrencyTest` (a separate `async: false`
    # module, mirroring `BotConfigTest`'s F-07 guard) rather than here,
    # since this whole file is `async: true`.
    test "the row-lock mechanism used by consume_patient_auth_code/3 compiles to FOR UPDATE SQL" do
      query = PatientAuthCode.for_update_query("any-code", "deep_link")

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
      assert sql =~ "FOR UPDATE"
    end
  end

  # --- helpers ---

  defp set_expires_at(auth_code, expires_at) do
    from(a in PatientAuthCode, where: a.id == ^auth_code.id)
    |> Repo.update_all(set: [expires_at: expires_at])
  end
end
