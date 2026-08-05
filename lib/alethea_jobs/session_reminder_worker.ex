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
end
