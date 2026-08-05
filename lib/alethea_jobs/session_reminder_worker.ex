defmodule AletheaJobs.SessionReminderWorker do
  @moduledoc """
  Telegram pre-session reminder (telegram-session-reminders, #97).

  Repurposed from the WhatsApp-only inert stub left by #87.
  `Alethea.Jobs.TelegramMessageWorker` enqueues this worker (scheduled
  for `next_session - 24h`) during a live inbound Telegram message —
  see `Alethea.Accounts.SessionSchedule.next_datetime/3` for the
  next-occurrence math and `schedule_session_reminder/3` for the
  enqueue site.

  `perform/1` does NOT call `Alethea.Telegram.Client` directly. It
  ENQUEUES a `Alethea.Jobs.TelegramOutboundWorker` job (mirrors the
  goodbye dispatch pattern, `session_timeout_worker.ex:253-259`) so
  the reminder inherits the outbound worker's `Pacer` rate-limiting
  and dead-letter/retry handling instead of bypassing them.

  `patient_id: nil` on the outbound args matches the goodbye
  convention — reminders are non-clinical logistics, so the outbound
  worker's dead-letter row has no patient to attribute.

  Uniqueness (`unique: [keys: [:patient_id, :session_date],
  period: :infinity]`) dedups repeated inbound-triggered enqueue
  attempts for the same upcoming session; a new `session_date` (next
  week's session) is a fresh key, so a new reminder is allowed.
  """
  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3,
    unique: [keys: [:patient_id, :session_date], period: :infinity]

  import Ecto.Query

  alias Alethea.Jobs.TelegramOutboundWorker

  @reminder_message "Recordatorio: tienes una sesión programada para mañana. Si no puedes asistir, avisa a tu terapeuta con anticipación."

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"chat_id" => chat_id, "chat_id_hash" => chat_id_hash}
      }) do
    %{
      chat_id: chat_id,
      chat_id_hash: chat_id_hash,
      body: @reminder_message,
      patient_id: nil
    }
    |> TelegramOutboundWorker.new()
    |> Oban.insert!()

    :ok
  end

  @doc """
  Cancels any pending (`scheduled`, `available`, or `retryable` state)
  reminder job for `patient_id` (session-reminder-reschedule-sync, #102).

  Called best-effort from `AletheaWeb.DashboardLive` after a successful
  `Alethea.Accounts.update_patient_session_schedule/3` so a stale
  reminder for the old schedule never fires. No re-enqueue happens
  here — the next inbound Telegram message re-enqueues for the new
  schedule via the untouched `schedule_session_reminder/3` path.

  `retryable` is included alongside the two pre-run states: a reminder
  that already ran, raised, and is awaiting a retry (`max_attempts: 3`)
  would otherwise survive the cancel and still deliver the stale
  old-schedule reminder. `executing` is intentionally excluded — an
  in-flight send cannot be meaningfully recalled.

  > ## Authorization contract
  >
  > This function scopes ONLY by `patient_id` — it has NO tenant/
  > professional boundary of its own. Callers MUST pass a `patient_id`
  > they have already authorized for the acting professional (the sole
  > caller, `DashboardLive`, resolves it via
  > `Accounts.get_patient_for_professional/2` before the id ever
  > reaches here). Do NOT call this with an unscoped or
  > user-supplied id, or it will cancel another professional's
  > patient's reminders.

  `Oban.cancel_all_jobs/1` (Oban 2.22, `Engine.cancel_all_jobs/2`
  callback contract) always returns `{:ok, non_neg_integer()}` — it
  has no `{:error, term()}` return shape to match on. The caller
  wraps this call in `try/rescue` for best-effort resilience against
  raised exceptions (e.g. a DB connectivity failure) instead of
  matching on an error tuple that cannot occur.
  """
  @spec cancel_pending(binary()) :: {:ok, non_neg_integer()}
  def cancel_pending(patient_id) do
    query =
      from j in Oban.Job,
        where: j.worker == "AletheaJobs.SessionReminderWorker",
        where: j.state in ["scheduled", "available", "retryable"],
        where: fragment("? ->> 'patient_id' = ?", j.args, ^to_string(patient_id))

    Oban.cancel_all_jobs(query)
  end
end
