defmodule Alethea.Accounts.SessionSchedule do
  @moduledoc """
  Pure weekly-session-slot math (telegram-session-reminders, #97).

  `next_datetime/3` computes the next weekly occurrence of a
  `session_day_of_week` + `session_time` slot (`Alethea.Accounts.Patient`,
  `patient.ex:15-16`), given a reference instant. It does NOT query the
  DB and has no side effects — it exists purely to isolate the
  wrap-around / same-day-time-passed math so it can be unit tested
  without any Oban/Ecto scaffolding.

  Reuses the `DateTime.new(date, time, "Etc/UTC")` convention already
  established by `AletheaJobs.DailySchedulerWorker` (`daily_scheduler_worker.ex:22`)
  to stay timezone-consistent with the rest of the scheduling code —
  `session_time` is stored tz-naive and interpreted as UTC.
  """

  @doc """
  Returns the next `DateTime` (UTC) at which the given
  `dow` (`1..7`, Monday..Sunday, `Date.day_of_week/1` convention) +
  `time` slot occurs, strictly after `from`.

  If today already matches `dow` but `time` has already passed (or is
  exactly equal to `from`), the result rolls forward to the same slot
  7 days later.
  """
  @spec next_datetime(1..7, Time.t(), DateTime.t()) :: DateTime.t()
  def next_datetime(dow, %Time{} = time, %DateTime{} = from \\ DateTime.utc_now())
      when dow in 1..7 do
    today = DateTime.to_date(from)
    days = Integer.mod(dow - Date.day_of_week(today) + 7, 7)

    {:ok, candidate} = DateTime.new(Date.add(today, days), time, "Etc/UTC")

    if DateTime.compare(candidate, from) == :gt do
      candidate
    else
      {:ok, next_week} = DateTime.new(Date.add(today, days + 7), time, "Etc/UTC")
      next_week
    end
  end
end
