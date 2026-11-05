defmodule AletheaJobs.ActiveTriggerWorker do
  @moduledoc """
  Oban worker that fires at the scheduled time of an active trigger (Issues #440, #441).
  Supports one-shot, daily, and weekly schedules until optional end_date.
  Defers during journaling, polling at most once per minute until the original
  due time plus one hour. Crisis protection still takes precedence.
  """
  use Oban.Worker,
    queue: :schedulers,
    max_attempts: 1,
    unique: [keys: [:trigger_id], states: [:scheduled, :available, :retryable]]

  import Ecto.Query

  alias Alethea.Clinical
  alias Alethea.Clinical.{Message, Session}
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.{Trigger, TriggerFiring}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trigger_id" => trigger_id}}) when is_binary(trigger_id) do
    Repo.transaction(fn ->
      case Repo.one(
             from t in Trigger, where: t.id == ^trigger_id, select: {t.patient_id, t.status}
           ) do
        {patient_id, "active"} ->
          :ok = Clinical.lock_patient_conversation!(patient_id)
          patient = Repo.get!(Alethea.Accounts.Patient, patient_id)

          query = from(t in Trigger, where: t.id == ^trigger_id, lock: "FOR UPDATE")

          case Repo.one(query) do
            %Trigger{status: "active", approved_text: approved_text} = trigger
            when not is_nil(approved_text) ->
              if patient.urgent_intervention do
                # S2: A due firing for a patient under urgent intervention is not sent
                paused =
                  trigger
                  |> Trigger.changeset(%{status: "paused_by_crisis"})
                  |> Repo.update!()

                Triggers.enqueue_trigger_rag_event(paused)

                Triggers.delete_scheduled_jobs(trigger.id)

                Triggers.insert_content_free_audit!(
                  trigger.professional_id,
                  trigger.id,
                  "trigger_paused_by_crisis"
                )

                :ok
              else
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
                      defer_during_journaling!(trigger, now)
                      now_sec = DateTime.truncate(now, :second)

                      if Triggers.count_daily_active_sends(
                           trigger.patient_id,
                           now,
                           patient.timezone
                         ) >= Triggers.daily_cap() do
                        # S4: The sixth send of the day for a patient is not sent and is recorded as skipped
                        case %TriggerFiring{}
                             |> TriggerFiring.changeset(%{
                               trigger_id: trigger.id,
                               message_id: nil,
                               status: "skipped",
                               fired_at: now_sec,
                               scheduled_at: trigger.scheduled_at
                             })
                             |> Repo.insert() do
                          {:ok, firing} ->
                            advance_trigger!(trigger)

                            Triggers.enqueue_firing_rag_event(firing)

                            Triggers.insert_content_free_audit!(
                              trigger.professional_id,
                              trigger.id,
                              "trigger_skipped"
                            )

                            :ok

                          {:error, %Ecto.Changeset{errors: errors}} ->
                            if Keyword.has_key?(errors, :trigger_id) or
                                 Keyword.has_key?(errors, :trigger_id_scheduled_at) do
                              Repo.rollback(:already_fired)
                            else
                              Repo.rollback({:firing_insert_error, errors})
                            end
                        end
                      else
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
                          {:ok, firing} ->
                            advance_trigger!(trigger)

                            Triggers.enqueue_firing_rag_event(firing)

                            Triggers.insert_content_free_audit!(
                              trigger.professional_id,
                              trigger.id,
                              "trigger_fired"
                            )

                            %{
                              "trigger_id" => trigger.id,
                              "message_id" => message.id,
                              "lane" => "trigger",
                              "approval_revision" => trigger.approval_revision
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
                      end

                    _already_fired ->
                      :ok
                  end
                end
              end

            _other ->
              :ok
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

  defp advance_trigger!(trigger) do
    case Triggers.next_occurrence(trigger, trigger.scheduled_at) do
      {:ok, next_instant} ->
        trigger
        |> Trigger.changeset(%{scheduled_at: next_instant})
        |> Repo.update!()

        %{"trigger_id" => trigger.id}
        |> __MODULE__.new(scheduled_at: next_instant)
        |> Oban.insert!()

      :none ->
        fired =
          trigger
          |> Trigger.changeset(%{status: "fired"})
          |> Repo.update!()

        Triggers.enqueue_trigger_rag_event(fired)
    end
  end

  defp defer_during_journaling!(trigger, now) do
    remaining = 3600 - DateTime.diff(now, trigger.scheduled_at, :second)

    if remaining > 0 and journaling_open?(trigger.patient_id) do
      Repo.rollback({:snooze, min(60, remaining)})
    end
  end

  defp journaling_open?(patient_id) do
    # SessionTimeoutWorker owns closure; do not invent a second inactivity clock.
    Repo.exists?(from(s in Session, where: s.patient_id == ^patient_id and s.status == "open")) or
      Clinical.uncovered_inbound?(patient_id) or Clinical.pending_reply_ids(patient_id) != []
  end
end
