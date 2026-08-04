defmodule AletheaJobs.DailySchedulerWorker do
  use Oban.Worker, queue: :schedulers

  import Ecto.Query
  alias Alethea.{Accounts.Patient, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tomorrow = Date.add(Date.utc_today(), 1)
    tomorrow_dow = Date.day_of_week(tomorrow)

    patients =
      Repo.all(
        from p in Patient,
          where:
            p.session_day_of_week == ^tomorrow_dow and
              not is_nil(p.session_time) and
              p.status == "active"
      )

    Enum.each(patients, fn patient ->
      {:ok, session_dt} = DateTime.new(tomorrow, patient.session_time)
      report_scheduled_at = DateTime.add(session_dt, -2 * 3600, :second)

      {:ok, _} =
        AletheaJobs.WeeklyReportWorker.new(%{patient_id: patient.id},
          scheduled_at: report_scheduled_at
        )
        |> Oban.insert()
    end)

    :ok
  end
end
