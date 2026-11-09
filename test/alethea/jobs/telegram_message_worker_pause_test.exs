defmodule Alethea.Jobs.TelegramMessageWorkerPauseTest do
  @moduledoc """
  Tests for the patient-facing `/pausa` command in
  `Alethea.Jobs.TelegramMessageWorker` (Issue #446).

  Covers the real `TelegramMessageWorker.perform/1` entry point:

    - Exact-match recognition (case-insensitive, trimmed) short-circuits
      before any persistence — no `Message` row for the command text.
    - Near-misses (`"pausa"`, `"necesito una pausa"`) are treated as
      ordinary journaling content, not the command.
    - Active-kind triggers move to `paused_by_patient`; reactive-kind
      triggers are untouched (end-to-end, through the real entry point —
      the domain-level assertion already lives in `triggers_test.exs`).
    - A fixed, non-AI confirmation is enqueued via `TelegramOutboundWorker`
      with no `message_id`.
    - The scheduled `ActiveTriggerWorker` job for each paused trigger is
      deleted.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Clinical.Message
  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger
  alias AletheaJobs.ActiveTriggerWorker

  import Alethea.FoundationTestHelper

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @pausa_confirmation "Listo, pausamos tus mensajes programados. Podés escribirme cuando quieras."

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    %{legacy_pro: legacy_pro, legacy_pat: legacy_pat} = bind_patient()
    %{professional: legacy_pro, patient: legacy_pat}
  end

  describe "perform/1 — /pausa command (Issue #446)" do
    test "exact match pauses active-kind triggers, leaves reactive-kind untouched, " <>
           "confirms, and persists no Message row",
         %{professional: professional, patient: patient} do
      future_date = Date.utc_today() |> Date.add(2)

      {:ok, active_trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Recordar respiración",
          approved_text: "Hola, recuerda respirar.",
          date: future_date,
          time: ~T[10:00:00]
        })

      {:ok, reactive_trigger} =
        Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
          "condition" => "Habla de una discusión con su madre",
          "instruction" => "Retomar el ejercicio de comunicación asertiva",
          "approved_text" => "Texto reactivo"
        })

      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => active_trigger.id})

      assert :ok = perform_inbound("/pausa", 601)

      # Active-kind trigger paused; reactive-kind untouched.
      assert Repo.get!(Trigger, active_trigger.id).status == "paused_by_patient"
      assert Repo.get!(Trigger, reactive_trigger.id).status == "active"

      # Scheduled job for the paused trigger is gone.
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => active_trigger.id})

      # The command text itself is never persisted as a Message.
      assert Repo.aggregate(Message, :count, :id) == 0

      # Fixed confirmation enqueued with no message_id (no clinical journal entry).
      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{chat_id_hash: @chat_id_hash, body: @pausa_confirmation, message_id: nil}
      )
    end

    test "case/whitespace variant is recognized the same way", %{
      professional: professional,
      patient: patient
    } do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      assert :ok = perform_inbound(" /Pausa ", 602)

      assert Repo.get!(Trigger, trigger.id).status == "paused_by_patient"
      assert Repo.aggregate(Message, :count, :id) == 0

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{chat_id_hash: @chat_id_hash, body: @pausa_confirmation, message_id: nil}
      )
    end

    test "near-misses are NOT recognized as the pause command", %{
      professional: professional,
      patient: patient
    } do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion",
          approved_text: "Texto",
          date: future_date,
          time: ~T[10:00:00]
        })

      for {text, telegram_update_id} <- [{"pausa", 603}, {"necesito una pausa", 604}] do
        assert :ok = perform_inbound(text, telegram_update_id)

        # Trigger is never touched by a near-miss.
        assert Repo.get!(Trigger, trigger.id).status == "active"
      end

      # Both near-misses are ordinary journaling content: persisted as
      # Message rows, not short-circuited like the real command.
      assert Repo.aggregate(Message, :count, :id) == 2

      refute_enqueued(worker: TelegramOutboundWorker, args: %{body: @pausa_confirmation})
    end
  end

  defp perform_inbound(text, telegram_update_id) do
    TelegramMessageWorker.perform(%Oban.Job{
      args: %{
        "telegram_update_id" => telegram_update_id,
        "message" => %{
          "message_id" => telegram_update_id,
          "date" => 1_700_000_000,
          "chat" => %{"id" => @chat_id, "type" => "private"},
          "text" => text
        }
      }
    })
  end

  defp bind_patient do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_pro)

    {:ok, legacy_pat} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_pro.id},
        kek
      )

    foundation_pat
    |> Ecto.Changeset.change(%{
      telegram_chat_id_hash: @chat_id_hash,
      legacy_patient_id: legacy_pat.id
    })
    |> Repo.update!()

    %{legacy_pro: legacy_pro, legacy_pat: legacy_pat}
  end

  defp unique_int, do: System.unique_integer([:positive])
end
