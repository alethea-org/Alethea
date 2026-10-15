defmodule Alethea.Jobs.TelegramMessageWorkerCrisisHistoryTest do
  @moduledoc """
  #399 acceptance: a crisis exchange followed by an ordinary message,
  driven through `Alethea.Jobs.TelegramMessageWorker.perform/1` with the
  AI worker boundary (`Alethea.AI.PhiWorkerMock`) controlled.

  The crisis exchange — the triggering inbound and its `crisis_bypass`
  reply — collapses into exactly one neutral placeholder turn both in
  the journaling history and in the running-summary window. Neither the
  triggering words nor the crisis copy ever reach the model.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query
  import Alethea.FoundationTestHelper
  import Alethea.RunningSummaryHelper, only: [valid_summary: 0]

  alias Alethea.AI.PhiWorkerMock
  alias Alethea.Clinical.CrisisExchange
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.{TelegramBurstReplyWorker, TelegramMessageWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias AletheaJobs.RunningSummaryWorker

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 399_399_399
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @crisis_text "me voy a quitar la vida"
  @crisis_copy "Contacta a tu terapeuta de inmediato, estamos contigo."

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)
    setup_bound_patient()
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "perform/1 — crisis exchange in journaling context (#399)" do
    test "the reply after a crisis exchange sees one placeholder turn, never the crisis copy nor the trigger",
         ctx do
      assert :ok = perform(@crisis_text, 1)
      backdate(ctx)

      payload = reply_payload("hoy salí a caminar", 2)

      # The whole exchange — trigger inbound + `crisis_bypass` reply —
      # is exactly one neutral placeholder turn.
      assert payload.history == [CrisisExchange.placeholder_turn()]
    end

    test "the running-summary window sees the same placeholder population", ctx do
      for n <- 1..9, do: assert(:ok = perform("mensaje #{n}", n))
      assert :ok = perform(@crisis_text, 10)
      backdate(ctx)
      assert :ok = perform("mensaje 11", 11)

      # The crisis trigger does not count toward the cadence: the job is
      # armed by "mensaje 11", the tenth JOURNALING inbound.
      assert [%{args: %{"patient_id" => id}}] = all_enqueued(worker: RunningSummaryWorker)
      assert id == ctx.legacy_patient.id

      request = drain_summary()

      contents = Enum.map(request.turns, & &1.content)
      assert length(request.turns) == 11
      assert Enum.count(contents, &(&1 == CrisisExchange.placeholder_text())) == 1
      refute @crisis_text in contents
      refute @crisis_copy in contents
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # `Clinical.save_message/7` stamps `DateTime.utc_now()` (second-
  # truncated), so rows written by one `perform/1` would tie-break
  # against the next one's by random UUID. Shifting every row back two
  # minutes pins the whole crisis exchange strictly before the next
  # message's row.
  defp backdate(ctx) do
    Repo.update_all(
      from(m in Message, where: m.patient_id == ^ctx.legacy_patient.id),
      set: [timestamp: DateTime.add(DateTime.utc_now(), -120, :second)]
    )
  end

  defp drain_summary do
    test_pid = self()

    expect(PhiWorkerMock, :summarize, fn request ->
      send(test_pid, {:summary_request, request})
      {:ok, %{summary: valid_summary(), truncated: false}}
    end)

    Oban.drain_queue(queue: :running_summary)
    assert_received {:summary_request, request}
    request
  end

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

  defp perform(text, n), do: TelegramMessageWorker.perform(%Oban.Job{args: build_args(text, n)})

  defp build_args(text, n) do
    %{
      "telegram_update_id" => 399_000 + n,
      "message" => %{
        "message_id" => 399_000 + n,
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
        crisis_message: @crisis_copy
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
