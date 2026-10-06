defmodule Alethea.Jobs.TelegramMessageWorkerIdempotencyTest do
  @moduledoc """
  Resume and duplicate-safety behavior of the Telegram journaling reply
  (issue #390), driven through `TelegramMessageWorker.perform/1` with the
  AI worker boundary controlled by `Alethea.AI.PhiWorkerMock` and delivery
  controlled by `Alethea.Telegram.Client.Fake`.

  One persisted patient message must complete its reply despite worker
  retries, concurrent executions, and outbound retries, without creating
  another patient-visible response.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox

  alias Alethea.Clinical.Message
  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, Client.Fake, Pacer}
  alias AletheaJobs.{ClinicalRecordOutboxWorker, EmotionAnalysisWorker}

  import Alethea.FoundationTestHelper
  import Ecto.Query

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @other_chat_id 987_654_321
  @reply "respuesta clínica"

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    Application.put_env(
      :alethea,
      Alethea.Telegram.Pacer,
      Keyword.merge(
        Application.get_env(:alethea, Alethea.Telegram.Pacer, []),
        per_chat_capacity: 5,
        per_chat_refill_per_sec: 50.0,
        global_capacity: 30,
        global_refill_per_sec: 30.0,
        cleanup_interval_ms: 60_000,
        idle_threshold_ms: 60_000
      )
    )

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

    {:ok, _} = Pacer.start_link([])

    start_supervised!(Fake)
    Fake.reset()
    Application.put_env(:alethea, :telegram_client, Fake)

    stub(Alethea.AI.PhiWorkerMock, :process, fn %{message_id: mid} -> phi_reply(mid) end)

    :ok
  end

  setup :verify_on_exit!

  describe "perform/1 — conversation-scoped inbound identity and resume" do
    test "a retry after reply generation failed resumes the persisted inbound and produces the reply" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 401, telegram_update_id: 11)
      test_pid = self()

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        send(test_pid, {:generation_for, mid})
        {:error, :service_unavailable}
      end)
      |> expect(:process, fn %{message_id: mid} ->
        send(test_pid, {:generation_for, mid})
        phi_reply(mid)
      end)

      assert_raise RuntimeError, ~r/PhiWorker error/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      assert [%Message{id: inbound_id}] = messages(patient, "inbound")
      refute_enqueued(worker: TelegramOutboundWorker)

      # The Oban retry of the same job: same args, inbound already persisted.
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert [%Message{id: ^inbound_id}] = messages(patient, "inbound")
      assert [%Message{behavior_type: "elicited"}] = messages(patient, "outbound")

      # Both attempts worked on the same persisted inbound.
      assert_received {:generation_for, ^inbound_id}
      assert_received {:generation_for, ^inbound_id}

      assert [%Oban.Job{args: %{"body" => @reply}}] =
               all_enqueued(worker: TelegramOutboundWorker)
    end

    test "resuming does not repeat the work the first execution completed for the inbound" do
      patient = bind_patient(@chat_id)
      args = build_args(@chat_id, "hola", telegram_message_id: 402, telegram_update_id: 12)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn _ -> {:error, :service_unavailable} end)
      |> expect(:process, fn %{message_id: mid} -> phi_reply(mid) end)

      assert_raise RuntimeError, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      [inbound] = messages(patient, "inbound")
      inbound_id = inbound.id

      # One sentiment-pipeline job and one patient-voice outbox event for
      # the one inbound, not one per execution.
      assert [%Oban.Job{args: %{"message_id" => ^inbound_id}}] =
               all_enqueued(worker: EmotionAnalysisWorker)

      assert [_one_event] = all_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "equal Telegram message ids in two patients' conversations do not collide" do
      first = bind_patient(@chat_id)
      second = bind_patient(@other_chat_id)

      first_args = build_args(@chat_id, "hola", telegram_message_id: 7, telegram_update_id: 21)

      second_args =
        build_args(@other_chat_id, "buen día", telegram_message_id: 7, telegram_update_id: 22)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: first_args})
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: second_args})

      assert [%Message{telegram_message_id: "7"} = first_inbound] = messages(first, "inbound")
      assert [%Message{telegram_message_id: "7"} = second_inbound] = messages(second, "inbound")
      refute first_inbound.id == second_inbound.id

      # Each conversation gets its own reply and its own delivery job.
      assert [_] = messages(first, "outbound")
      assert [_] = messages(second, "outbound")

      chat_ids =
        [worker: TelegramOutboundWorker]
        |> all_enqueued()
        |> Enum.map(& &1.args["chat_id"])
        |> Enum.sort()

      assert chat_ids == [@chat_id, @other_chat_id]
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp phi_reply(message_id) do
    {:ok,
     %{
       response: @reply,
       source_message_id: message_id,
       model_version: "phi-4-mini",
       behavior_type: :elicited
     }}
  end

  defp build_args(chat_id, text, opts) do
    %{
      "telegram_update_id" => Keyword.fetch!(opts, :telegram_update_id),
      "message" => %{
        "message_id" => Keyword.fetch!(opts, :telegram_message_id),
        "date" => 1_700_000_000,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "text" => text
      }
    }
  end

  defp messages(%{legacy_patient: legacy_patient}, direction) do
    Repo.all(
      from(m in Message,
        where: m.patient_id == ^legacy_patient.id and m.direction == ^direction,
        order_by: m.inserted_at
      )
    )
  end

  defp bind_patient(chat_id, crisis_message \\ "Estoy aquí para ayudarte. Llamame al 0800-...") do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    legacy_pro =
      legacy_pro
      |> Ecto.Changeset.change(%{crisis_message: crisis_message})
      |> Repo.update!()

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_pro)

    {:ok, legacy_pat} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_pro.id},
        kek
      )

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: ChatIdHash.hash(chat_id, @pepper),
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    %{
      foundation_patient: foundation_pat,
      legacy_patient: Alethea.Accounts.get_patient_with_professional(legacy_pat.id),
      chat_id: chat_id
    }
  end

  defp unique_int, do: System.unique_integer([:positive])
end
