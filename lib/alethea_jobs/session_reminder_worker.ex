defmodule AletheaJobs.SessionReminderWorker do
  @moduledoc """
  Retired in #87 alongside the WhatsApp messaging path.

  Session reminders were WhatsApp-only; they have no Telegram equivalent yet
  (tracked in #97). No new reminder jobs are enqueued — `DailySchedulerWorker`
  no longer schedules this worker. This module is kept as an inert no-op so any
  Oban job scheduled before the retirement (reminders are queued up to ~24h
  ahead) resolves cleanly to `:ok` instead of crashing on a missing module.

  When #97 lands, this module is either repurposed for the Telegram reminder or
  removed once no scheduled jobs can reference it.
  """
  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
