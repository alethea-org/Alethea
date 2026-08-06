defmodule Alethea.Jobs.TelegramMessageWorkerReminderTest do
  @moduledoc """
  Tests for the session-reminder enqueue trigger added to
  `Alethea.Jobs.TelegramMessageWorker` (telegram-session-reminders,
  #97, Phase 3).

  Covers REQ scenarios from `openspec/sdd/telegram-session-reminders/02-spec.md`:

    - "Patient has schedule and Telegram binding, window still open"
      -> `AletheaJobs.SessionReminderWorker` enqueued.
    - "Reminder window already past" (24h guard) -> no enqueue.
    - "No schedule configured" -> no enqueue.
    - "Repeated inbound messages within the same window" -> exactly
      one scheduled job (idempotent dedup on `[:patient_id, :session_date]`).

  Reuses the same bound-patient + inbound-perform pattern as
  `test/alethea/jobs/telegram_message_worker_test.exs` (safe path,
  `describe "perform/1 — happy path safe clinical round-trip"`).
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox
  import Ecto.Query

  alias Alethea.Jobs.TelegramMessageWorker
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias AletheaJobs.SessionReminderWorker

  import Alethea.FoundationTestHelper

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 246_813_579
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    Alethea.AI.PhiWorkerMock
    |> stub(:process, fn %{message_id: mid} ->
      {:ok,
       %{
         response: "respuesta clínica",
         source_message_id: mid,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}
    end)

    :ok
  end

  setup :verify_on_exit!

  describe "schedule_session_reminder/3 (called after :167 in process_bound_message/6)" do
    test "window still open: enqueues a SessionReminderWorker job for (patient_id, session_date)" do
      # Schedule the session 3 days out so `reminder_at` (next_session - 24h)
      # is unambiguously still in the future, regardless of the current
      # time-of-day when this test runs.
      target_date = Date.add(Date.utc_today(), 3)
      dow = Date.day_of_week(target_date)
      time = ~T[12:00:00]

      %{legacy_patient: legacy_patient} =
        setup_bound_patient(schedule: {dow, time})

      args = build_args("hola, buen día", telegram_message_id: 900, telegram_update_id: 900)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      expected_session_date = Date.to_iso8601(target_date)

      assert_enqueued(
        worker: SessionReminderWorker,
        args: %{
          patient_id: legacy_patient.id,
          session_date: expected_session_date,
          chat_id: @chat_id,
          chat_id_hash: @chat_id_hash
        }
      )

      [job] =
        Repo.all(from(j in Oban.Job, where: j.worker == "AletheaJobs.SessionReminderWorker"))

      expected_reminder_at =
        target_date
        |> DateTime.new!(time, "Etc/UTC")
        |> DateTime.add(-24, :hour)

      assert_in_delta DateTime.diff(job.scheduled_at, expected_reminder_at, :second), 0, 5
    end

    test "24h guard: reminder window already past (next_session - 24h <= now) -> no enqueue" do
      # Derive the schedule from "now + 2h" so next_session lands well
      # inside the 24h window (reminder_at is ~22h in the past).
      soon = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      dow = Date.day_of_week(DateTime.to_date(soon))
      time = DateTime.to_time(soon) |> Time.truncate(:second)

      setup_bound_patient(schedule: {dow, time})

      args = build_args("hola, buen día", telegram_message_id: 901, telegram_update_id: 901)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      refute_enqueued(worker: SessionReminderWorker)
    end

    test "no schedule configured (nil session_day_of_week/session_time) -> no enqueue" do
      setup_bound_patient(schedule: nil)

      args = build_args("hola, buen día", telegram_message_id: 902, telegram_update_id: 902)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      refute_enqueued(worker: SessionReminderWorker)
    end

    test "idempotency: two inbound messages in the same window enqueue exactly one job" do
      target_date = Date.add(Date.utc_today(), 3)
      dow = Date.day_of_week(target_date)
      time = ~T[12:00:00]

      setup_bound_patient(schedule: {dow, time})

      first_args =
        build_args("primer mensaje", telegram_message_id: 903, telegram_update_id: 903)

      second_args =
        build_args("segundo mensaje", telegram_message_id: 904, telegram_update_id: 904)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: first_args})
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: second_args})

      assert length(all_enqueued(worker: SessionReminderWorker)) == 1
    end
  end

  # ----------------------------------------------------------------
  # Fixtures (self-contained — mirrors
  # test/alethea/jobs/telegram_message_worker_test.exs's
  # setup_bound_patient/1 pattern, extended with an optional schedule).
  # ----------------------------------------------------------------

  defp setup_bound_patient(opts) do
    schedule = Keyword.get(opts, :schedule)

    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    legacy_pro = insert_legacy_professional()
    legacy_pat = insert_legacy_patient(legacy_pro, "alias-#{unique_int()}")

    legacy_pat =
      case schedule do
        {dow, time} ->
          {:ok, updated} =
            Alethea.Accounts.update_patient_session_schedule(legacy_pat, dow, time)

          updated

        nil ->
          legacy_pat
      end

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: @chat_id_hash,
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    legacy_pat = Alethea.Accounts.get_patient_with_professional(legacy_pat.id)

    %{
      foundation_patient: foundation_pat,
      legacy_patient: legacy_pat,
      chat_id_hash: @chat_id_hash
    }
  end

  defp insert_legacy_professional do
    {:ok, pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    pro
  end

  defp insert_legacy_patient(professional, alias_name) do
    {:ok, kek} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{
          "alias" => alias_name,
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end

  defp build_args(text, opts) do
    %{
      telegram_update_id: Keyword.fetch!(opts, :telegram_update_id),
      message: %{
        "message_id" => Keyword.fetch!(opts, :telegram_message_id),
        "date" => 1_700_000_000,
        "chat" => %{"id" => @chat_id, "type" => "private"},
        "text" => text
      }
    }
  end

  defp unique_int, do: System.unique_integer([:positive])
end
