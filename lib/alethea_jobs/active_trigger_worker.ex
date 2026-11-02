defmodule AletheaJobs.ActiveTriggerWorker do
  @moduledoc """
  Oban worker that fires at the scheduled time of an active one-shot trigger (Issue #440, S3/S6).
  """
  use Oban.Worker,
    queue: :schedulers,
    max_attempts: 1,
    unique: [keys: [:trigger_id], period: :infinity]

  import Ecto.Query

  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
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
            case Repo.get_by(TriggerFiring, trigger_id: trigger.id) do
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
                       fired_at: now_sec
                     })
                     |> Repo.insert() do
                  {:ok, _firing} ->
                    trigger
                    |> Trigger.changeset(%{status: "fired"})
                    |> Repo.update!()

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

                  {:error, %Ecto.Changeset{errors: [trigger_id: _]}} ->
                    # B3: Concurrency defense against duplicate insert race
                    Repo.rollback(:already_fired)
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
