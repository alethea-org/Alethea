defmodule Alethea.Clinical.SessionSummariesPaginationTest do
  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  alias Alethea.Clinical
  alias Alethea.Clinical.Summary
  alias Alethea.Repo

  setup do
    professional = legacy_professional_fixture()
    patient = legacy_patient_fixture(professional)
    other_patient = legacy_patient_fixture(professional)
    since = DateTime.utc_now() |> DateTime.add(-30, :day)

    %{patient: patient, other_patient: other_patient, since: since}
  end

  describe "list_session_summaries_page/3" do
    test "returns the newest page first and reports more items", %{patient: patient, since: since} do
      ids = insert_sessions(patient, 25)

      {page, more?} = Clinical.list_session_summaries_page(patient.id, since, limit: 20)

      assert length(page) == 20
      assert more?
      # insert_sessions returns ids newest first
      assert Enum.map(page, & &1.id) == Enum.take(ids, 20)
    end

    test "the cursor fetches only the next page and reports the end", %{
      patient: patient,
      since: since
    } do
      ids = insert_sessions(patient, 25)

      {page, true} = Clinical.list_session_summaries_page(patient.id, since, limit: 20)
      last = List.last(page)

      {next, more?} =
        Clinical.list_session_summaries_page(patient.id, since,
          limit: 20,
          before: {last.period_end, last.id}
        )

      assert Enum.map(next, & &1.id) == Enum.drop(ids, 20)
      refute more?
    end

    test "breaks period_end ties by id without skipping or repeating", %{
      patient: patient,
      since: since
    } do
      period_end = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      for _ <- 1..5, do: insert_session(patient, period_end)

      {first, true} = Clinical.list_session_summaries_page(patient.id, since, limit: 3)
      last = List.last(first)

      {second, false} =
        Clinical.list_session_summaries_page(patient.id, since,
          limit: 3,
          before: {last.period_end, last.id}
        )

      all_ids = Enum.map(first ++ second, & &1.id)
      assert length(all_ids) == 5
      assert Enum.uniq(all_ids) == all_ids
    end

    test "defaults to a page size of 20 and keeps patient, type and window filters", %{
      patient: patient,
      other_patient: other_patient,
      since: since
    } do
      insert_sessions(patient, 21)
      insert_sessions(other_patient, 3)
      insert_session(patient, DateTime.utc_now() |> DateTime.add(-40, :day), "session")
      insert_session(patient, DateTime.utc_now() |> DateTime.add(-1, :day), "weekly")

      {page, more?} = Clinical.list_session_summaries_page(patient.id, since)

      assert length(page) == 20
      assert more?
      assert Enum.all?(page, &(&1.patient_id == patient.id and &1.type == "session"))
    end

    test "with no more items than the limit reports no more", %{patient: patient, since: since} do
      insert_sessions(patient, 20)

      {page, more?} = Clinical.list_session_summaries_page(patient.id, since, limit: 20)

      assert length(page) == 20
      refute more?
    end
  end

  describe "list_session_summaries/2 (unchanged)" do
    test "still returns every session summary in the window, unpaginated", %{
      patient: patient,
      since: since
    } do
      ids = insert_sessions(patient, 25)

      result = Clinical.list_session_summaries(patient.id, since)

      assert Enum.sort(Enum.map(result, & &1.id)) == Enum.sort(ids)
    end
  end

  # Inserts `count` session summaries, one hour apart, and returns their ids
  # ordered newest first.
  defp insert_sessions(patient, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for n <- 1..count do
      insert_session(patient, DateTime.add(now, -n, :hour)).id
    end
  end

  defp insert_session(patient, period_end, type \\ "session") do
    period_end = DateTime.truncate(period_end, :second)

    %Summary{}
    |> Summary.changeset(%{
      period_start: period_end,
      period_end: period_end,
      summary_text: "Resumen #{System.unique_integer([:positive])}",
      status_level: "Estable",
      type: type,
      patient_id: patient.id
    })
    |> Repo.insert!()
  end
end
