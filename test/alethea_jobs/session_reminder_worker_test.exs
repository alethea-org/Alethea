defmodule AletheaJobs.SessionReminderWorkerTest do
  @moduledoc """
  Tests for `AletheaJobs.SessionReminderWorker` (telegram-session-reminders,
  #97, Phase 2).

  `perform/1` ENQUEUES a `Alethea.Jobs.TelegramOutboundWorker` job
  (mirrors the goodbye dispatch, `session_timeout_worker.ex:253-259`) —
  it does not call `Telegram.Client` directly, so `Pacer` +
  dead-letter/retry are inherited from the outbound worker.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Telegram.{Client.Fake, Pacer}
  alias AletheaJobs.SessionReminderWorker

  @chat_id 555_666_777
  @chat_id_hash String.duplicate("b", 64)

  setup do
    Application.put_env(
      :alethea,
      Alethea.Telegram.Pacer,
      Keyword.merge(
        Application.get_env(:alethea, Alethea.Telegram.Pacer, []),
        per_chat_capacity: 1,
        per_chat_refill_per_sec: 1.0,
        global_capacity: 30,
        global_refill_per_sec: 30.0,
        cleanup_interval_ms: 60_000,
        idle_threshold_ms: 60_000
      )
    )

    {:ok, _} = safe_start_pacer()

    start_supervised!(Fake)
    Fake.reset()
    Application.put_env(:alethea, :telegram_client, Fake)

    Repo.delete_all(Oban.Job)

    :ok
  end

  describe "Oban.Worker contract" do
    test "uses the :sessions queue and max_attempts: 3" do
      assert SessionReminderWorker.__opts__()[:queue] == :sessions
      assert SessionReminderWorker.__opts__()[:max_attempts] == 3
    end

    test "unique on [:patient_id, :session_date] for :infinity" do
      assert SessionReminderWorker.__opts__()[:unique] ==
               [keys: [:patient_id, :session_date], period: :infinity]
    end
  end

  describe "perform/1" do
    test "enqueues a TelegramOutboundWorker job with the static reminder body, patient_id: nil" do
      args = %{
        "patient_id" => Ecto.UUID.generate(),
        "session_date" => "2024-01-10",
        "chat_id" => @chat_id,
        "chat_id_hash" => @chat_id_hash
      }

      assert :ok = perform_job(SessionReminderWorker, args)

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{
          chat_id: @chat_id,
          chat_id_hash: @chat_id_hash,
          patient_id: nil
        }
      )

      [job] =
        Repo.all(
          Ecto.Query.from(j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker"
          )
        )

      assert job.args["body"] =~ "Recordatorio"
    end

    test "the enqueued outbound job delivers the static Spanish reminder via the Fake client" do
      args = %{
        "patient_id" => Ecto.UUID.generate(),
        "session_date" => "2024-01-10",
        "chat_id" => @chat_id,
        "chat_id_hash" => @chat_id_hash
      }

      assert :ok = perform_job(SessionReminderWorker, args)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :telegram_outbound)

      sends = Fake.sends()
      assert length(sends) == 1
      [send] = sends
      assert send.chat_id == @chat_id
      assert send.text =~ "Recordatorio: tienes una sesión programada para mañana."
    end
  end

  defp safe_start_pacer do
    case Process.whereis(Pacer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end

    Pacer.start_link([])
  end
end
