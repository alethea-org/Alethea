defmodule AletheaJobs.TelegramDeliverySweepWorkerTest do
  @moduledoc """
  `AletheaJobs.TelegramDeliverySweepWorker` (issue #390): a journaling
  reply whose delivery claim was never resolved must not stay in
  `sending` forever. After a bounded time it becomes `ambiguous` (never
  resent) and is surfaced through the outbound dead-letter path, once.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.FoundationTestHelper
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Foundation.Accounts.OutboundDeadLetter
  alias Alethea.Repo
  alias AletheaJobs.TelegramDeliverySweepWorker

  @chat_id_hash String.duplicate("b", 64)
  @other_chat_id_hash String.duplicate("c", 64)
  @patient_words "hoy me sentí muy mal"
  @reply "respuesta clínica"

  setup do
    Repo.delete_all(Oban.Job)
    Phoenix.PubSub.subscribe(Alethea.PubSub, "ops:alerts")
    %{patient: bound_patient()}
  end

  test "runs from cron every five minutes on the journaling outbound queue" do
    assert TelegramDeliverySweepWorker.__opts__()[:queue] == :telegram_outbound

    crontab =
      :alethea
      |> Application.get_env(Oban)
      |> Keyword.fetch!(:plugins)
      |> Keyword.fetch!(Oban.Plugins.Cron)
      |> Keyword.fetch!(:crontab)

    assert {"*/5 * * * *", TelegramDeliverySweepWorker} in crontab
  end

  test "the bound exceeds the Telegram client's request timeout with margin" do
    # Req's defaults: 30s to connect plus 15s to receive. A send that is
    # merely slow must have long finished before its claim can expire.
    assert TelegramDeliverySweepWorker.claim_timeout_seconds() >= 10 * 45
  end

  test "a claim older than the bound becomes ambiguous and is surfaced through the dead-letter path",
       %{patient: patient} do
    reply = claimed_reply(patient)
    expire_claim(reply)

    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})

    assert Clinical.telegram_delivery_state(reply.id) == "ambiguous"

    assert [dead_letter] = Repo.all(OutboundDeadLetter)
    assert dead_letter.outcome == "ambiguous"
    assert dead_letter.lane == "safe"
    assert dead_letter.last_error == "{:ambiguous, :claim_expired}"
    assert dead_letter.patient_id == patient.foundation_patient.id
    assert dead_letter.chat_id_hash == @chat_id_hash

    assert_receive {:outbound_dead_letter,
                    %{outcome: "ambiguous", lane: "safe", chat_id_hash: @chat_id_hash} = payload}

    # Same payload an exhausted delivery carries: the reply text, never
    # the patient's own words.
    assert dead_letter.text == @reply
    assert payload.text == @reply
    refute inspect(dead_letter) =~ @patient_words
    refute inspect(payload) =~ @patient_words
  end

  test "running the sweep twice surfaces the reply once", %{patient: patient} do
    reply = claimed_reply(patient)
    expire_claim(reply)

    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})
    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})

    assert Repo.aggregate(OutboundDeadLetter, :count) == 1
    assert_receive {:outbound_dead_letter, _}
    refute_receive {:outbound_dead_letter, _}, 50
  end

  test "a claim still within the bound is left alone", %{patient: patient} do
    reply = claimed_reply(patient)

    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})

    assert Clinical.telegram_delivery_state(reply.id) == "sending"
    assert Repo.aggregate(OutboundDeadLetter, :count) == 0
    refute_receive {:outbound_dead_letter, _}, 50
  end

  test "old replies that already have an outcome are left alone", %{patient: patient} do
    sent = claimed_reply(patient, 2)
    :ok = Clinical.record_telegram_delivery(sent.id, {:sent, 4242})
    pending = pending_reply(patient, 3)

    expire_claim(sent)
    expire_claim(pending)

    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})

    assert Clinical.telegram_delivery_state(sent.id) == "sent"
    assert Clinical.telegram_delivery_state(pending.id) == "pending"
    assert Repo.aggregate(OutboundDeadLetter, :count) == 0
  end

  test "an acknowledgement that arrives after the sweep still wins", %{patient: patient} do
    reply = claimed_reply(patient)
    expire_claim(reply)
    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})

    # The slow holder finally hears back from Telegram.
    assert :ok = Clinical.record_telegram_delivery(reply.id, {:sent, 777})
    assert Clinical.telegram_delivery_state(reply.id) == "sent"

    assert :ok = perform_job(TelegramDeliverySweepWorker, %{})
    assert Clinical.telegram_delivery_state(reply.id) == "sent"
  end

  describe "a stale claim whose resolution fails" do
    setup %{patient: healthy} do
      failing = bound_patient(@other_chat_id_hash)

      # The failing reply is the OLDEST stale claim, so it is attempted
      # first on every run.
      failing_reply = claimed_reply(failing)
      healthy_reply = claimed_reply(healthy)
      expire_claim(failing_reply, 2 * 86_400)
      expire_claim(healthy_reply, 86_400)
      corrupt_chat_hash(failing)

      %{failing: failing, failing_reply: failing_reply, healthy_reply: healthy_reply}
    end

    test "does not stop the remaining stale claims from being resolved and surfaced",
         %{failing_reply: failing_reply, healthy_reply: healthy_reply} do
      log =
        capture_log(fn ->
          assert {:error, _} = perform_job(TelegramDeliverySweepWorker, %{})
        end)

      assert Clinical.telegram_delivery_state(healthy_reply.id) == "ambiguous"
      assert [dead_letter] = Repo.all(OutboundDeadLetter)
      assert dead_letter.chat_id_hash == @chat_id_hash
      assert_receive {:outbound_dead_letter, %{chat_id_hash: @chat_id_hash}}
      refute_receive {:outbound_dead_letter, _}, 50

      # The failing row is all-or-nothing: no state change, no dead-letter.
      assert Clinical.telegram_delivery_state(failing_reply.id) == "sending"

      # It is reported, by id and a fixed label only.
      assert log =~ "could not resolve expired delivery claim"
      assert log =~ failing_reply.id
      refute log =~ @reply
      refute log =~ @patient_words
      refute log =~ "not-a-chat-hash"
    end

    test "reports the failed run as an error without content, after attempting every row" do
      capture_log(fn ->
        assert {:error, reason} = perform_job(TelegramDeliverySweepWorker, %{})
        send(self(), {:reason, reason})
      end)

      assert_received {:reason, reason}
      assert reason == "1 of 2 expired delivery claims could not be resolved"
    end

    test "is picked up by a later run once the cause is gone, and nothing is surfaced twice",
         %{failing: failing, failing_reply: failing_reply, healthy_reply: healthy_reply} do
      capture_log(fn ->
        assert {:error, _} = perform_job(TelegramDeliverySweepWorker, %{})
        # Still failing: the healthy reply, already resolved, is not
        # reported again by the rerun.
        assert {:error, "1 of 1 " <> _} = perform_job(TelegramDeliverySweepWorker, %{})
      end)

      assert Repo.aggregate(OutboundDeadLetter, :count) == 1

      set_chat_hash(failing.foundation_patient, @other_chat_id_hash)

      assert :ok = perform_job(TelegramDeliverySweepWorker, %{})

      assert Clinical.telegram_delivery_state(failing_reply.id) == "ambiguous"
      assert Clinical.telegram_delivery_state(healthy_reply.id) == "ambiguous"

      hashes = OutboundDeadLetter |> Repo.all() |> Enum.map(& &1.chat_id_hash) |> Enum.sort()
      assert hashes == Enum.sort([@chat_id_hash, @other_chat_id_hash])

      assert :ok = perform_job(TelegramDeliverySweepWorker, %{})
      assert Repo.aggregate(OutboundDeadLetter, :count) == 2
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp pending_reply(%{foundation_patient: foundation_patient}, n) do
    {:ok, inbound} =
      Clinical.find_or_save_telegram_inbound(foundation_patient, @patient_words, "#{n}", nil)

    {:ok, reply} =
      Clinical.save_telegram_reply(foundation_patient, @reply, "elicited", inbound.id, nil)

    # #391: production never has an uncovered inbound at claim time for a
    # genuine reply — the burst/crisis save transaction covers its
    # members atomically with the reply. This fixture bypasses that
    # transaction, so it must cover the inbound itself or the dispatch
    # claim (design AD7) would see an uncovered row for this patient and
    # supersede instead of claiming.
    Repo.update_all(from(m in Message, where: m.id == ^inbound.id),
      set: [replied_by_message_id: reply.id]
    )

    reply
  end

  defp claimed_reply(patient, n \\ 1) do
    reply = pending_reply(patient, n)
    :claimed = Clinical.claim_telegram_delivery(reply.id)
    reply
  end

  defp expire_claim(%Message{id: id}, seconds_ago \\ 86_400) do
    long_ago =
      DateTime.add(DateTime.utc_now(), -seconds_ago, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(m in Message, where: m.id == ^id), set: [updated_at: long_ago])
  end

  # Makes surfacing this patient's replies raise: a dead-letter row
  # rejects a chat hash that is not 64 characters.
  defp corrupt_chat_hash(%{foundation_patient: foundation_patient}) do
    set_chat_hash(foundation_patient, "not-a-chat-hash")
  end

  # Written by id: the struct held by the test may be stale.
  defp set_chat_hash(%{id: id}, chat_id_hash) do
    Repo.update_all(
      from(p in Alethea.Foundation.Accounts.Patient, where: p.id == ^id),
      set: [telegram_chat_id_hash: chat_id_hash]
    )
  end

  defp bound_patient(chat_id_hash \\ @chat_id_hash) do
    foundation_pat =
      patient_fixture(professional_fixture(), %{alias: "Pat#{unique_int()}"})

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

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: chat_id_hash,
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    %{foundation_patient: foundation_pat, legacy_patient: legacy_pat}
  end

  defp unique_int, do: System.unique_integer([:positive])
end
