defmodule Alethea.ClinicalTest do
  use Alethea.DataCase, async: true

  alias Alethea.{Accounts, Clinical}

  describe "latest_weekly_summary/1" do
    setup do
      {:ok, professional} =
        Accounts.create_professional(%{
          email: "test-#{System.unique_integer([:positive])}@alethea.com",
          password: "password1234",
          full_name: "Dra. Test"
        })

      {:ok, patient} =
        Accounts.create_patient(%{
          alias: "Paciente Semanal",
          professional_id: professional.id
        })

      %{patient: patient}
    end

    test "returns nil when the patient has no weekly summary", %{patient: patient} do
      insert_summary(patient, "session", days_ago: 1)

      refute Clinical.latest_weekly_summary(patient.id)
    end

    test "returns the weekly summary even when its period started over a week ago", %{
      patient: patient
    } do
      insert_summary(patient, "session", days_ago: 2)
      weekly = insert_summary(patient, "weekly", days_ago: 9)

      assert %{id: id, type: "weekly"} = Clinical.latest_weekly_summary(patient.id)
      assert id == weekly.id
    end

    test "returns the most recent weekly summary", %{patient: patient} do
      insert_summary(patient, "weekly", days_ago: 21)
      newest = insert_summary(patient, "weekly", days_ago: 7)

      assert %{id: id} = Clinical.latest_weekly_summary(patient.id)
      assert id == newest.id
    end

    test "ignores weekly summaries belonging to another patient", %{patient: patient} do
      {:ok, other_professional} =
        Accounts.create_professional(%{
          email: "other-#{System.unique_integer([:positive])}@alethea.com",
          password: "password1234",
          full_name: "Dr. Otro"
        })

      {:ok, other_patient} =
        Accounts.create_patient(%{
          alias: "Otro Paciente",
          professional_id: other_professional.id
        })

      insert_summary(other_patient, "weekly", days_ago: 1)

      refute Clinical.latest_weekly_summary(patient.id)
    end
  end

  defp insert_summary(patient, type, days_ago: days_ago) do
    period_start =
      DateTime.utc_now()
      |> DateTime.add(-days_ago, :day)
      |> DateTime.truncate(:second)

    period_end = DateTime.add(period_start, 7, :day)

    {:ok, summary} =
      Clinical.save_summary(%{
        period_start: period_start,
        period_end: period_end,
        summary_text: "Resumen #{type} #{days_ago}",
        status_level: "stable",
        type: type,
        patient_id: patient.id
      })

    summary
  end
end
