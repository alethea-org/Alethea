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

  describe "cancel_pending/1" do
    test "happy path: cancels a real pending job and returns {:ok, 1}" do
      patient_id = Ecto.UUID.generate()

      {:ok, job} =
        %{
          "patient_id" => patient_id,
          "session_date" => "2099-01-10",
          "chat_id" => @chat_id,
          "chat_id_hash" => @chat_id_hash
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      assert {:ok, 1} = SessionReminderWorker.cancel_pending(patient_id)

      assert Repo.get(Oban.Job, job.id).state == "cancelled"
    end

    test "scoping: only cancels the pending job for the given patient" do
      patient_a = Ecto.UUID.generate()
      patient_b = Ecto.UUID.generate()

      {:ok, job_a} =
        %{
          "patient_id" => patient_a,
          "session_date" => "2099-01-10",
          "chat_id" => @chat_id,
          "chat_id_hash" => @chat_id_hash
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      {:ok, job_b} =
        %{
          "patient_id" => patient_b,
          "session_date" => "2099-01-11",
          "chat_id" => @chat_id,
          "chat_id_hash" => @chat_id_hash
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      assert {:ok, 1} = SessionReminderWorker.cancel_pending(patient_a)

      assert Repo.get(Oban.Job, job_a.id).state == "cancelled"
      assert Repo.get(Oban.Job, job_b.id).state == "scheduled"
    end

    test "worker-string pin: the enqueued job's worker field literal-equals the cancel query filter" do
      patient_id = Ecto.UUID.generate()

      {:ok, job} =
        %{
          "patient_id" => patient_id,
          "session_date" => "2099-01-10",
          "chat_id" => @chat_id,
          "chat_id_hash" => @chat_id_hash
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      assert job.worker == "AletheaJobs.SessionReminderWorker"
    end

    test "no pending reminder exists: completes without error and changes nothing" do
      patient_id = Ecto.UUID.generate()
      other_patient_id = Ecto.UUID.generate()

      {:ok, other_job} =
        %{
          "patient_id" => other_patient_id,
          "session_date" => "2099-01-10",
          "chat_id" => @chat_id,
          "chat_id_hash" => @chat_id_hash
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      assert {:ok, 0} = SessionReminderWorker.cancel_pending(patient_id)

      assert Repo.get(Oban.Job, other_job.id).state == "scheduled"
    end

    test "cancels a job awaiting retry (retryable state)" do
      patient_id = Ecto.UUID.generate()

      {:ok, job} =
        %{
          "patient_id" => patient_id,
          "session_date" => "2099-01-10",
          "chat_id" => @chat_id,
          "chat_id_hash" => @chat_id_hash
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      # A reminder that already fired, raised, and is awaiting a retry
      # (max_attempts: 3) sits in "retryable" — it must still be cancelled
      # on a schedule change, or it would deliver the stale reminder.
      {:ok, _} = job |> Ecto.Changeset.change(state: "retryable") |> Repo.update()

      assert {:ok, 1} = SessionReminderWorker.cancel_pending(patient_id)

      assert Repo.get(Oban.Job, job.id).state == "cancelled"
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
