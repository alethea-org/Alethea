defmodule AletheaJobs.ActiveTriggerWorker do
  @moduledoc """
  Oban worker that fires at the scheduled time of an active trigger (Issues #440, #441).
  Supports one-shot, daily, and weekly schedules until optional end_date.
  """
  use Oban.Worker,
    queue: :schedulers,
    max_attempts: 1,
    unique: [keys: [:trigger_id], states: [:scheduled, :available, :retryable]]

  import Ecto.Query

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trigger_id" => trigger_id}}) when is_binary(trigger_id) do
    Repo.transaction(fn ->
      query = from(t in Trigger, where: t.id == ^trigger_id, lock: "FOR UPDATE")

      case Repo.one(query) do
        %Trigger{status: "active"} = trigger ->
          now = DateTime.utc_now()

          # B1: Verify scheduled_at against actual clock before ANY mutation
          if DateTime.compare(trigger.scheduled_at, now) == :gt do
            delay = max(DateTime.diff(trigger.scheduled_at, now, :second), 1)
            Repo.rollback({:snooze, delay})
          else
            case Repo.get_by(TriggerFiring,
                   trigger_id: trigger.id,
                   scheduled_at: trigger.scheduled_at
                 ) do
              nil ->
                now_sec = DateTime.truncate(now, :second)

                # B5: Set trigger_id programmatically, not from untrusted changeset attrs
                message =
                  %Message{}
                  |> Message.changeset(%{
                    patient_id: trigger.patient_id,
                    direction: "outbound",
                    behavior_type: "spontaneous",
                    encrypted_content: trigger.approved_text,
                    timestamp: now_sec
                  })
                  |> Ecto.Changeset.put_change(:delivery_state, "pending")
                  |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
                  |> Repo.insert!()

                # B4: Truthful firing status "fired" (not "sent") before Telegram ack
                case %TriggerFiring{}
                     |> TriggerFiring.changeset(%{
                       trigger_id: trigger.id,
                       message_id: message.id,
                       status: "fired",
                       fired_at: now_sec,
                       scheduled_at: trigger.scheduled_at
                     })
                     |> Repo.insert() do
                  {:ok, _firing} ->
                    # Recurrence check: schedule next occurrence or finish trigger
                    case Triggers.next_occurrence(trigger, trigger.scheduled_at) do
                      {:ok, next_instant} ->
                        trigger
                        |> Trigger.changeset(%{scheduled_at: next_instant})
                        |> Repo.update!()

                        %{"trigger_id" => trigger.id}
                        |> __MODULE__.new(scheduled_at: next_instant)
                        |> Oban.insert!()

                      :none ->
                        trigger
                        |> Trigger.changeset(%{status: "fired"})
                        |> Repo.update!()
                    end

                    %AuditLog{}
                    |> AuditLog.changeset(%{
                      professional_id: trigger.professional_id,
                      action: "trigger_fired",
                      resource_type: "trigger",
                      resource_id: trigger.id,
                      details: %{}
                    })
                    |> Repo.insert!()

                    %{
                      "trigger_id" => trigger.id,
                      "message_id" => message.id,
                      "lane" => "trigger"
                    }
                    |> TelegramOutboundWorker.new()
                    |> Oban.insert!()

                    :ok

                  {:error, %Ecto.Changeset{errors: errors}} ->
                    if Keyword.has_key?(errors, :trigger_id) or
                         Keyword.has_key?(errors, :trigger_id_scheduled_at) do
                      # B3: Concurrency defense against duplicate insert race
                      Repo.rollback(:already_fired)
                    else
                      Repo.rollback({:firing_insert_error, errors})
                    end
                end

              _already_fired ->
                :ok
            end
          end

        _other ->
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:snooze, delay}} -> {:snooze, delay}
      {:error, :already_fired} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: :ok
end
