defmodule Alethea.Jobs.TelegramMessageWorkerRunningSummaryTest do
  @moduledoc """
  Behavior tests for the running summary integration (#394), driven
  through `Alethea.Jobs.TelegramMessageWorker.perform/1` with the AI
  worker boundary (`Alethea.AI.PhiWorkerMock`) controlled.

  The trigger is asserted on the enqueued `RunningSummaryWorker` job; the
  reply integration on the payload that reaches `process/1` once the
  armed burst-reply job (#391) runs.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox
  import Ecto.Query
  import ExUnit.CaptureLog
  import Alethea.FoundationTestHelper

  import Alethea.RunningSummaryHelper,
    only: [valid_summary: 0, put_row: 7, disable_local_endpoint: 0]

  alias Alethea.Accounts.AuditLog
  alias Alethea.AI.PhiWorkerMock
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Clinical.RunningSummary.Snapshot
  alias Alethea.Jobs.{TelegramBurstReplyWorker, TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, JournalingReply}
  alias AletheaJobs.RunningSummaryWorker

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 394_394_394
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)
    setup_bound_patient()
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "trigger" do
    test "the tenth inbound enqueues one job carrying only the patient id", ctx do
      inbound(1..9)
      assert all_enqueued(worker: RunningSummaryWorker) == []

      inbound(10..10)

      assert [%{args: args}] = all_enqueued(worker: RunningSummaryWorker)
      assert args == %{"patient_id" => ctx.legacy_patient.id}
    end

    test "replaying the ninth inbound does not change the count or enqueue a job" do
      inbound(1..8)
      inbound(9..9)
      inbound(9..9)

      assert all_enqueued(worker: RunningSummaryWorker) == []
    end

    test "a crisis inbound counts toward the cadence", ctx do
      inbound(1..9)
      assert :ok = perform("Quiero morir", 10)

      assert [%{args: %{"patient_id" => id}}] = all_enqueued(worker: RunningSummaryWorker)
      assert id == ctx.legacy_patient.id
    end

    test "a scheduling failure never fails the inbound", ctx do
      inbound(1..9)
      Repo.query!("ALTER TABLE running_summaries RENAME TO running_summaries_broken")

      log = capture_log(fn -> assert :ok = perform("mensaje 10", 10) end)

      assert log =~ "RunningSummary: schedule_if_due failed"
      assert all_enqueued(worker: RunningSummaryWorker) == []
      assert Repo.aggregate(inbounds(ctx), :count) == 10
    end

    test "the tenth inbound enqueues nothing while the summary is disabled (no local endpoint)" do
      inbound(1..9)
      disable_local_endpoint()

      assert :ok = perform("mensaje 10", 10)

      assert all_enqueued(worker: RunningSummaryWorker) == []
    end

    test "the summary produces no delivery job of its own" do
      inbound(1..10)
      drain_summary(ok_summary())

      assert all_enqueued(worker: TelegramOutboundWorker) == []
    end
  end

  describe "reply integration" do
    test "once the job has run, the next reply's request carries the summary" do
      inbound(1..10)
      drain_summary(ok_summary())

      payload = reply_payload("mensaje 11", 11)

      assert payload.summary == valid_summary()
      assert String.ends_with?(payload.sanitized_content, "mensaje 11")
    end

    test "a multi-message burst reply carries the summary and loads it exactly once", ctx do
      inbound(1..10)
      drain_summary(ok_summary())
      before = audit_reasons(ctx)

      test_pid = self()

      expect(PhiWorkerMock, :process, fn payload ->
        send(test_pid, {:ai_worker_payload, payload})

        {:ok,
         %{
           response: "Gracias por contarlo. ¿Cómo lo viviste?",
           source_message_id: payload.message_id,
           model_version: "phi-4-mini",
           behavior_type: :elicited
         }}
      end)

      assert :ok = perform("mensaje 11", 11)
      assert :ok = perform("mensaje 12", 12)

      assert [job] = all_enqueued(worker: TelegramBurstReplyWorker)
      assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: job.args})
      assert_receive {:ai_worker_payload, payload}

      assert payload.summary == valid_summary()
      assert payload.sanitized_content =~ "mensaje 11"
      assert String.ends_with?(payload.sanitized_content, "mensaje 12")

      added = audit_reasons(ctx) -- before
      assert Enum.count(added, &(&1 == "running_summary_loading")) == 1
    end

    test "a failed generation still delivers the reply with the previous summary intact" do
      inbound(1..10)
      drain_summary(ok_summary())
      inbound(11..20)
      drain_summary({:error, :generation_failed})

      assert %{covered_inbound_count: 10} = Repo.one!(Snapshot)

      payload = reply_payload("mensaje 21", 21)

      assert payload.summary == valid_summary()
      assert [_] = all_enqueued(worker: TelegramOutboundWorker)
    end

    test "without a row the request keeps exactly the three original keys" do
      payload = reply_payload("primer mensaje", 1)

      assert payload |> Map.keys() |> Enum.sort() == [:history, :message_id, :sanitized_content]
    end

    test "a stored summary that carries the current crisis copy is not attached", ctx do
      store_row(ctx, copy_summary(ctx))

      payload = reply_payload("mensaje", 1)

      assert payload |> Map.keys() |> Enum.sort() == [:history, :message_id, :sanitized_content]
    end

    test "a malformed stored summary is not attached", ctx do
      store_row(ctx, "texto libre sin secciones")

      payload = reply_payload("mensaje", 1)

      refute Map.has_key?(payload, :summary)
    end

    test "identifiers inside a stored summary are redacted", ctx do
      store_row(
        ctx,
        "Hechos que la persona relató:\n- Escribió a ana@example.com y al +56 9 8765 4321\n\n" <>
          "Preguntas que Alethea hizo:\n- ¿Cómo dormiste?"
      )

      payload = reply_payload("mensaje", 1)

      refute payload.summary =~ "ana@example.com"
      refute payload.summary =~ "8765 4321"
      assert payload.summary =~ "[REDACTED_EMAIL]"
      assert payload.summary =~ "[REDACTED_PHONE]"
    end

    test "a summary that cannot be decrypted degrades to a reply without it, logging only the message id",
         ctx do
      store_row(ctx, valid_summary())
      Repo.update_all(Snapshot, set: [encrypted_summary: <<0, 1, 2, 3>>])

      log =
        capture_log(fn ->
          payload = reply_payload("mensaje", 1)
          refute Map.has_key?(payload, :summary)
        end)

      assert log =~ "running summary unavailable"
      assert [_] = all_enqueued(worker: TelegramOutboundWorker)
      refute log =~ "Salió a caminar"
    end

    test "a different patient's summary is never attached", ctx do
      other_professional = legacy_professional_fixture()
      other_patient = legacy_patient_fixture(other_professional)
      {:ok, other_dek} = Clinical.patient_dek(other_patient)

      {:ok, message} =
        Clinical.save_message(other_patient, "otro paciente", other_dek, "inbound", "spontaneous")

      put_row(
        other_patient,
        other_dek,
        "Hechos que la persona relató:\n- OTRA-PERSONA\n\nPreguntas que Alethea hizo:\n- ¿Qué tal?",
        :first,
        0,
        10,
        message
      )

      payload = reply_payload("mensaje", 1)

      refute Map.has_key?(payload, :summary)
      assert ctx.legacy_patient.id != other_patient.id
    end

    test "the job args and the request carry no key material", ctx do
      inbound(1..10)
      [job] = all_enqueued(worker: RunningSummaryWorker)
      assert Map.keys(job.args) == ["patient_id"]

      drain_summary(ok_summary())
      payload = reply_payload("mensaje 11", 11)

      {:ok, dek} = Clinical.patient_dek(ctx.legacy_patient)
      refute inspect(payload) =~ Base.encode64(dek)
      refute inspect(job.args) =~ Base.encode64(dek)
    end
  end

  describe "audit" do
    test "generating a reply with a stored summary writes exactly two PII_DECRYPT rows", ctx do
      store_row(ctx, valid_summary())
      inbound = persisted_inbound(ctx)
      before = audit_reasons(ctx)

      generate(ctx, inbound)

      assert Enum.sort(audit_reasons(ctx) -- before) ==
               ["clinical_context_loading", "running_summary_loading"]
    end

    test "generating a reply without a stored summary writes exactly one", ctx do
      inbound = persisted_inbound(ctx)
      before = audit_reasons(ctx)

      generate(ctx, inbound)

      assert audit_reasons(ctx) -- before == ["clinical_context_loading"]
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp ok_summary, do: {:ok, %{summary: valid_summary(), truncated: false}}

  defp drain_summary(result) do
    expect(PhiWorkerMock, :summarize, fn _request -> result end)
    Oban.drain_queue(queue: :running_summary)
  end

  # Performs the inbound for each n in `range` ("mensaje n").
  defp inbound(range) do
    for n <- range, do: assert(:ok = perform("mensaje #{n}", n))
    :ok
  end

  defp perform(text, n), do: TelegramMessageWorker.perform(%Oban.Job{args: build_args(text, n)})

  # Performs one inbound, runs the armed burst-reply job and returns the
  # payload that reached `process/1`.
  defp reply_payload(text, n) do
    test_pid = self()

    expect(PhiWorkerMock, :process, fn payload ->
      send(test_pid, {:ai_worker_payload, payload})

      {:ok,
       %{
         response: "Gracias por contarlo. ¿Cómo lo viviste?",
         source_message_id: payload.message_id,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}
    end)

    assert :ok = perform(text, n)
    [job] = all_enqueued(worker: TelegramBurstReplyWorker)
    assert :ok = TelegramBurstReplyWorker.perform(%Oban.Job{args: job.args})
    assert_receive {:ai_worker_payload, payload}
    payload
  end

  defp persisted_inbound(ctx) do
    {:ok, message} =
      Clinical.save_telegram_message(
        ctx.foundation_patient,
        "hola",
        "inbound",
        "spontaneous",
        nil
      )

    message
  end

  defp generate(ctx, inbound) do
    expect(PhiWorkerMock, :process, fn payload ->
      {:ok,
       %{
         response: "Gracias por contarlo. ¿Cómo lo viviste?",
         source_message_id: payload.message_id,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}
    end)

    assert {:ok, _} = JournalingReply.generate(ctx.foundation_patient, inbound, "hola")
  end

  defp store_row(ctx, text) do
    {:ok, dek} = Clinical.patient_dek(ctx.legacy_patient)

    {:ok, message} =
      Clinical.save_message(ctx.legacy_patient, "ancla", dek, "inbound", "spontaneous")

    put_row(ctx.legacy_patient, dek, text, :first, 0, 10, message)
  end

  defp copy_summary(ctx) do
    patient = Alethea.Accounts.get_patient_with_professional(ctx.legacy_patient.id)

    "Hechos que la persona relató:\n- #{Alethea.Alerts.CrisisCopy.reply_text(patient)}\n\n" <>
      "Preguntas que Alethea hizo:\n- ¿Cómo dormiste?"
  end

  defp audit_reasons(ctx) do
    AuditLog
    |> where([a], a.resource_id == ^ctx.legacy_patient.id and a.action == "PII_DECRYPT")
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> Repo.all()
    |> Enum.map(& &1.details["reason"])
  end

  defp inbounds(ctx) do
    from(m in Message, where: m.patient_id == ^ctx.legacy_patient.id and m.direction == "inbound")
  end

  defp build_args(text, n) do
    %{
      "telegram_update_id" => 39_400 + n,
      "message" => %{
        "message_id" => 39_400 + n,
        "date" => 1_700_000_000,
        "chat" => %{"id" => @chat_id, "type" => "private"},
        "text" => text
      }
    }
  end

  defp setup_bound_patient do
    foundation_patient = patient_fixture(professional_fixture(), %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_professional} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}",
        crisis_message: "Contacta a tu terapeuta de inmediato, estamos contigo."
      })

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_professional)

    {:ok, legacy_patient} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_professional.id},
        kek
      )

    foundation_patient =
      foundation_patient
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: @chat_id_hash,
        legacy_patient_id: legacy_patient.id
      })
      |> Repo.update!()

    [foundation_patient: foundation_patient, legacy_patient: legacy_patient]
  end

  defp unique_int, do: System.unique_integer([:positive])
end
