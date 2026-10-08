defmodule Alethea.Migrations.BurstCoverageTest do
  @moduledoc """
  R10 (pre-existing rows excluded): the backfill self-reference
  (`replied_by_message_id = id`, design AD2) applied by
  `AddBurstCoverageToMessages.up/0` marks a pre-#391 inbound row as
  "legacy, outside the burst model" — it must never become a burst
  member.

  This project migrates the sandboxed test database once at suite
  boot (`mix test` → `ecto.migrate` → `test`), not inside each test's
  own transaction, so re-running the real `up/0` per test is
  impractical without a second, non-sandboxed connection (flagged in
  tasks.md 2.1). Migration files are also not loaded by `mix test`'s
  normal compile step, so the backfill SQL lives in
  `Alethea.Clinical.BurstBackfill` (a `lib/` module the migration
  calls into) instead of on the migration module itself. This test
  proves the invariant the backfill establishes — a self-referencing
  row is permanently excluded — by calling that SQL directly against
  rows inserted inside the sandbox, then asserting
  `Clinical.list_burst_members/1` on them.
  """

  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  alias Alethea.Clinical
  alias Alethea.Clinical.BurstBackfill

  setup do
    legacy_professional = legacy_professional_fixture()
    legacy_patient = legacy_patient_fixture(legacy_professional)

    foundation_professional = professional_fixture()

    foundation_patient =
      foundation_professional
      |> patient_fixture()
      |> Ecto.Changeset.change(%{legacy_patient_id: legacy_patient.id})
      |> Repo.update!()

    %{foundation_patient: foundation_patient}
  end

  test "a pre-existing inbound row, backfilled with the self-reference marker, is never a burst member",
       %{foundation_patient: foundation_patient} do
    {:ok, _legacy_row} =
      Clinical.save_telegram_message(
        foundation_patient,
        "legado",
        "inbound",
        "spontaneous",
        "100"
      )

    Repo.query!(BurstBackfill.sql())

    assert Clinical.list_burst_members(foundation_patient) == {:ok, []}
  end

  test "an inbound row written after the backfill, still uncovered, is a burst member", %{
    foundation_patient: foundation_patient
  } do
    {:ok, inbound} =
      Clinical.save_telegram_message(foundation_patient, "nuevo", "inbound", "spontaneous", "101")

    assert {:ok, [{member, "nuevo"}]} = Clinical.list_burst_members(foundation_patient)
    assert member.id == inbound.id
  end
end
