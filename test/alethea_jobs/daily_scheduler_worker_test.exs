defmodule AletheaJobs.DailySchedulerWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Ecto.Query

  alias Alethea.{Accounts, Repo}
  alias AletheaJobs.{DailySchedulerWorker, WeeklyReportWorker}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, professional} =
      Accounts.create_professional(%{
        email: "scheduler_test@example.com",
        password: "securepassword123",
        full_name: "Scheduler Tester"
      })

    %{professional: professional}
  end

  test "enqueues WeeklyReportWorker only for patients whose session is tomorrow", %{
    professional: professional
  } do
    tomorrow = Date.add(Date.utc_today(), 1)
    tomorrow_dow = Date.day_of_week(tomorrow)
    other_dow = rem(tomorrow_dow, 7) + 1

    dummy_enc = Alethea.Encryption.Vault.encrypt!("+5400000000")

    matching_patient =
      Repo.insert!(%Alethea.Accounts.Patient{
        alias: "Matching Patient",
        professional_id: professional.id,
        whatsapp_number_hash: Ecto.UUID.generate(),
        encrypted_whatsapp_number: dummy_enc,
        session_day_of_week: tomorrow_dow,
        session_time: ~T[10:00:00],
        status: "active"
      })

    _non_matching =
      Repo.insert!(%Alethea.Accounts.Patient{
        alias: "Non-Matching Patient",
        professional_id: professional.id,
        whatsapp_number_hash: Ecto.UUID.generate(),
        encrypted_whatsapp_number: dummy_enc,
        session_day_of_week: other_dow,
        session_time: ~T[10:00:00],
        status: "active"
      })

    assert :ok = perform_job(DailySchedulerWorker, %{})

    assert_enqueued(worker: WeeklyReportWorker, args: %{patient_id: matching_patient.id})

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "AletheaJobs.WeeklyReportWorker"
      )

    assert length(jobs) == 1
    [job] = jobs

    expected_dt = DateTime.new!(tomorrow, ~T[10:00:00])
    expected_scheduled_at = DateTime.add(expected_dt, -2 * 3600, :second)

    assert DateTime.diff(job.scheduled_at, expected_scheduled_at, :second) == 0
  end

  test "does not enqueue jobs for patients without session_time", %{professional: professional} do
    tomorrow_dow = Date.day_of_week(Date.add(Date.utc_today(), 1))

    Repo.insert!(%Alethea.Accounts.Patient{
      alias: "No Time Patient",
      professional_id: professional.id,
      whatsapp_number_hash: Ecto.UUID.generate(),
      encrypted_whatsapp_number: Alethea.Encryption.Vault.encrypt!("+5400000001"),
      session_day_of_week: tomorrow_dow,
      session_time: nil,
      status: "active"
    })

    assert :ok = perform_job(DailySchedulerWorker, %{})

    refute_enqueued(worker: WeeklyReportWorker)
  end
end
