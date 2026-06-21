defmodule Alethea.Jobs.TelegramMessageWorkerTest do
  @moduledoc """
  Tests for `Alethea.Jobs.TelegramMessageWorker` (C-3 inbound worker +
  C-5 safe clinical round-trip; PR #3a).

  Covers the **safe path** that PR #3a ships:

    - REQ-C3-worker-resolves-patient: `lookup_patient_by_chat_hash/1`
      resolution; unknown hash → one-shot "unregistered" outbound reply.
    - REQ-C3-worker-persists-message: inbound `Message` persisted via
      `Clinical.save_telegram_message/7` with `telegram_message_id`,
      `direction: "inbound"`, `source: "spontaneous"`.
    - REQ-C3-worker-emits-outbound-job: safe-path emits a
      `TelegramOutboundWorker` job on `:telegram_outbound`.
    - REQ-C5-persist-inbound-message: empty text payloads are dropped.
    - REQ-C5-trigger-emotion-analysis: `EmotionAnalysisWorker` enqueued
      on `:ai_analysis`.
    - REQ-C5-llm-reply-on-safe: LLM called via `Alethea.AI.llm().chat/2`,
      outbound `Message` persisted with `direction: "outbound"`,
      `source: "elicited"`.
    - REQ-C5-llm-unavailability: LLM error raises (Oban retry-eligible).

  The crisis branch (`:crisis_detected` PubSub, `:telegram_outbound_crisis`
  lane, no LLM bypass) is out of scope for this PR — it lands in PR #3b.

  ## Worker contract (preserved from PR #1b / #2 stub)

  The Oban.Worker `use` macro declares:
    - queue `:telegram_inbound`
    - `max_attempts: 3` (spec REQ-C3; the PR #2 stub had `max_attempts: 5`
      because the body was a no-op; PR #3a aligns with the spec)
    - `unique: [period: 86_400, keys: [:telegram_update_id]]`
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Clinical.Message
  alias Alethea.Repo
  alias AletheaJobs.EmotionAnalysisWorker
  alias Alethea.Telegram.ChatIdHash

  import Alethea.FoundationTestHelper
  import Ecto.Query

  # Inline test doubles for the LLM adapter. Defined at the module
  # level (NOT inside each test) so ExUnit does not redefine them on
  # every invocation. Each test sets `:test_pid` via Process.put and
  # the adapter reads it via Process.get to forward the call.
  defmodule ProbeLLM do
    @behaviour Alethea.AI.LLM
    def chat(messages, _opts) do
      test_pid = Process.get(:telegram_test_pid)
      send(test_pid, {:llm_called, messages})
      {:ok, %{content: "probe-reply", usage: nil, model: "probe-llm"}}
    end

    def generate(_prompt, _opts), do: {:ok, "probe-completion"}
  end

  defmodule FailingLLM do
    @behaviour Alethea.AI.LLM
    def chat(_messages, _opts), do: {:error, :service_unavailable}
    def generate(_prompt, _opts), do: {:ok, "fake"}
  end

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @unregistered_copy "Hola. No reconozco este chat en nuestro sistema clínico. Si eres un paciente, por favor contacta a tu terapeuta para que te registre."

  setup do
    # Pepper is required by `ChatIdHash.hash/2` (raises on < 32 bytes).
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    # Deterministic LLM adapter for tests.
    Application.put_env(:alethea, :ai_llm, Alethea.AI.LLM.Fake)
    # Forward LLM calls to the test pid so `ProbeLLM` can record them.
    Process.put(:telegram_test_pid, self())
    # Hermetic Oban queue state: every test starts with an empty
    # `oban_jobs` table so `assert_enqueued` does not pick up jobs from
    # other tests.
    Repo.delete_all(Oban.Job)
    :ok
  end

  # ----------------------------------------------------------------
  # Oban.Worker contract (REQ-C3-idempotent-by-update-id)
  # ----------------------------------------------------------------

  describe "Oban.Worker contract — preserved from PR #1b / #2 stub" do
    test "uses the :telegram_inbound queue" do
      assert TelegramMessageWorker.__opts__()[:queue] == :telegram_inbound
    end

    test "24h unique window on :telegram_update_id" do
      assert TelegramMessageWorker.__opts__()[:unique] ==
               [period: 86_400, keys: [:telegram_update_id]]
    end

    test "max_attempts is 3 per spec REQ-C3 (was 5 in PR #2 stub)" do
      assert TelegramMessageWorker.__opts__()[:max_attempts] == 3
    end
  end

  # ----------------------------------------------------------------
  # Unknown patient → "unregistered" reply (REQ-C3-worker-resolves-patient)
  # ----------------------------------------------------------------

  describe "perform/1 — unknown chat_id_hash" do
    test "returns :ok and enqueues a TelegramOutboundWorker with the unregistered copy" do
      args = build_args("hola", telegram_message_id: 100, telegram_update_id: 1)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{chat_id_hash: @chat_id_hash, body: @unregistered_copy, lane: :safe}
      )
    end

    test "no Message row is persisted for an unknown patient" do
      args = build_args("hola", telegram_message_id: 100, telegram_update_id: 2)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert Repo.aggregate(Message, :count, :id) == 0
    end

    test "the chat_id hash is NOT logged in any log line (R-1 PHI hygiene)" do
      args = build_args("hola", telegram_message_id: 100, telegram_update_id: 3)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
        end)

      refute log =~ @chat_id_hash
      refute log =~ "123456789"
    end
  end

  # ----------------------------------------------------------------
  # Empty text payload (REQ-C5-persist-inbound-message)
  # ----------------------------------------------------------------

  describe "perform/1 — empty text payload (sticker / voice / photo without caption)" do
    setup :setup_bound_patient

    test "returns :ok, no Message persisted, no outbound job enqueued", ctx do
      args = build_args(nil, telegram_message_id: 200, telegram_update_id: 4)
      _ = ctx

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert Repo.aggregate(Message, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)
      refute_enqueued(worker: EmotionAnalysisWorker)
    end
  end

  # ----------------------------------------------------------------
  # Happy path: safe clinical round-trip (REQ-C5)
  # ----------------------------------------------------------------

  describe "perform/1 — happy path safe clinical round-trip" do
    setup :setup_bound_patient

    test "persists inbound Message with telegram_message_id, direction: 'inbound', behavior_type: 'spontaneous'",
         ctx do
      args = build_args("hola, buen día", telegram_message_id: 300, telegram_update_id: 5)
      _ = ctx

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      inbound = Repo.one(from m in Message, where: m.direction == "inbound")
      assert inbound
      assert inbound.telegram_message_id == "300"
      assert inbound.direction == "inbound"
      assert inbound.behavior_type == "spontaneous"
      assert inbound.patient_id == ctx.legacy_patient.id
    end

    test "enqueues an EmotionAnalysisWorker job on :ai_analysis", ctx do
      args = build_args("hola, buen día", telegram_message_id: 301, telegram_update_id: 6)
      _ = ctx

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert_enqueued(worker: EmotionAnalysisWorker)
    end

    test "calls the LLM via Alethea.AI.llm().chat/2 with the patient context", ctx do
      Application.put_env(:alethea, :ai_llm, ProbeLLM)
      args = build_args("hola, buen día", telegram_message_id: 302, telegram_update_id: 7)
      _ = ctx

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert_received {:llm_called, messages}
      assert is_list(messages)
      assert Enum.any?(messages, &match?(%{role: :user, content: c} when is_binary(c), &1))
    end

    test "persists the outbound Message with direction: 'outbound', behavior_type: 'elicited'",
         ctx do
      args = build_args("hola, buen día", telegram_message_id: 303, telegram_update_id: 8)
      _ = ctx

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      outbound = Repo.one(from m in Message, where: m.direction == "outbound")
      assert outbound
      assert outbound.direction == "outbound"
      assert outbound.behavior_type == "elicited"
      assert outbound.patient_id == ctx.legacy_patient.id
    end

    test "enqueues a TelegramOutboundWorker job on :telegram_outbound (safe lane)",
         ctx do
      args = build_args("hola, buen día", telegram_message_id: 304, telegram_update_id: 9)
      _ = ctx

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{chat_id_hash: @chat_id_hash, lane: :safe}
      )

      # NO crisis-lane enqueue in PR #3a.
      safe_jobs = Repo.all(from j in Oban.Job, where: j.queue == "telegram_outbound_crisis")
      assert safe_jobs == []
    end
  end

  # ----------------------------------------------------------------
  # Failure modes (REQ-C3 / REQ-C5)
  # ----------------------------------------------------------------

  describe "perform/1 — failure modes" do
    setup :setup_bound_patient

    test "inbound persistence failure raises (Oban retries; no outbound enqueued)", ctx do
      _ = ctx

      # Pre-insert a Message with telegram_message_id "401" so the
      # worker's insert collides on the partial unique index.
      Repo.insert!(%Message{
        direction: "inbound",
        behavior_type: "spontaneous",
        encrypted_content: <<0>>,
        telegram_message_id: "401",
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
        patient_id: ctx.legacy_patient.id
      })

      collision_args = build_args("hola", telegram_message_id: 401, telegram_update_id: 11)

      # The worker uses `{:ok, _} = Clinical.save_telegram_message(...)`
      # which raises a MatchError on `{:error, changeset}`. The
      # constraint error is caught by `save_message/8` and converted
      # to a changeset error (REQ-C5-persist-outbound-reply
      # "persistence failure blocks the send"); the worker propagates
      # by raising MatchError so Oban schedules a retry.
      assert_raise MatchError, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: collision_args})
      end

      # No outbound was enqueued (the inbound did not succeed).
      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "LLM unavailability raises (Oban retries the job)", ctx do
      Application.put_env(:alethea, :ai_llm, FailingLLM)
      args = build_args("hola", telegram_message_id: 500, telegram_update_id: 12)
      _ = ctx

      assert_raise RuntimeError, ~r/service_unavailable/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      # The inbound persisted but no outbound was enqueued.
      assert Repo.aggregate(Message, :count) == 1
      refute_enqueued(worker: TelegramOutboundWorker)
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

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

  defp setup_bound_patient(_ctx) do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    legacy_pro = insert_legacy_professional()
    legacy_pat = insert_legacy_patient(legacy_pro, "alias-#{unique_int()}")

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: @chat_id_hash,
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    [
      foundation_patient: foundation_pat,
      legacy_patient: legacy_pat,
      chat_id_hash: @chat_id_hash
    ]
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
          "whatsapp_number" => "+5491#{:rand.uniform(99_999_999)}",
          "alias" => alias_name,
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end

  defp unique_int, do: System.unique_integer([:positive])
end
