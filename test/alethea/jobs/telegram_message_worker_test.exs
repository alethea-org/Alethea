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
  # Crisis branch (REQ-C5-crisis-bypasses-llm, REQ-C5-crisis-broadcasts-alert,
  #                REQ-C5-persist-outbound-reply — crisis source)
  # ----------------------------------------------------------------

  describe "perform/1 — crisis branch" do
    setup :setup_bound_patient

    setup do
      # Each crisis test subscribes to the psychologist alerts topic
      # to assert the broadcast shape.
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")
      :ok
    end

    test "on :crisis classification, the LLM is NOT invoked (REQ-C5 scenario: never produces a neutral LLM reply)",
         ctx do
      Application.put_env(:alethea, :ai_llm, ProbeLLM)
      _ = ctx

      text = "me voy a quitar la vida"

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args: build_args(text, telegram_message_id: 700, telegram_update_id: 70)
               })

      # ProbeLLM records calls by sending a message to the test pid.
      # No call should arrive.
      refute_received {:llm_called, _}, 200
    end

    test "persists the inbound Message with direction: 'inbound', behavior_type: 'spontaneous' (crisis share the inbound path)",
         ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a suicidar",
                     telegram_message_id: 701,
                     telegram_update_id: 71
                   )
               })

      inbound = Repo.one(from m in Message, where: m.direction == "inbound")
      assert inbound
      assert inbound.telegram_message_id == "701"
      assert inbound.behavior_type == "spontaneous"
      assert inbound.patient_id == ctx.legacy_patient.id
    end

    test "marks the patient as urgent_intervention: true (REQ-C5-crisis-bypasses-llm 'marks urgent_intervention')",
         ctx do
      _ = ctx

      assert ctx.legacy_patient.urgent_intervention == false

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a matar", telegram_message_id: 702, telegram_update_id: 72)
               })

      updated = Alethea.Accounts.get_patient!(ctx.legacy_patient.id)
      assert updated.urgent_intervention == true
    end

    test "saves a crisis-bypass ai_diagnosis row (REQ-C5 'Clinical.save_ai_diagnosis ... model_version: crisis-bypass')",
         ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("tengo el plan y los medios",
                     telegram_message_id: 703,
                     telegram_update_id: 73
                   )
               })

      inbound = Repo.one(from m in Message, where: m.direction == "inbound")
      diagnosis = Repo.one(from d in Alethea.AI.Diagnosis, where: d.message_id == ^inbound.id)

      assert diagnosis
      assert diagnosis.model_version == "crisis-bypass"
      assert diagnosis.ai_response == ctx.legacy_patient.professional.crisis_message
      assert diagnosis.extracted_emotions["crisis"] == true
      assert diagnosis.extracted_emotions["level"] == "immediate"
    end

    test "broadcasts :crisis_detected on 'psychologist:alerts' PubSub (REQ-C5-crisis-broadcasts-alert)",
         ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a suicidar",
                     telegram_message_id: 704,
                     telegram_update_id: 74
                   )
               })

      assert_receive {:crisis_detected,
                      %{
                        patient_id: patient_id,
                        chat_id_hash: chat_id_hash,
                        level: level,
                        triggers: triggers,
                        at: at
                      }},
                     1_000

      assert patient_id == ctx.legacy_patient.id
      assert chat_id_hash == @chat_id_hash
      assert level in [:immediate, :high, :low]
      assert is_list(triggers)
      assert is_struct(at, DateTime)
    end

    test "uses the legacy Patient's professional.crisis_message as the outbound body", ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a quitar la vida",
                     telegram_message_id: 705,
                     telegram_update_id: 75
                   )
               })

      outbound = Repo.one(from m in Message, where: m.direction == "outbound")
      assert outbound

      # The crisis-bypass reply lives in the legacy Professional's
      # `crisis_message` field; the test helper seeds it with the
      # default text. The outbound Message body is encrypted via
      # Clinical.save_message, so we decrypt to assert.
      assert decrypted_outbound_body(outbound) == ctx.legacy_patient.professional.crisis_message
    end

    test "persists the outbound Message with direction: 'outbound', behavior_type: 'crisis_bypass' (REQ-C5-persist-outbound-reply 'crisis_bypass source')",
         ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a matar", telegram_message_id: 706, telegram_update_id: 76)
               })

      outbound = Repo.one(from m in Message, where: m.direction == "outbound")
      assert outbound
      assert outbound.behavior_type == "crisis_bypass"
    end

    test "enqueues a TelegramOutboundWorker on :telegram_outbound_crisis with lane: :crisis",
         ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a suicidar",
                     telegram_message_id: 707,
                     telegram_update_id: 77
                   )
               })

      # The crisis lane enqueue has `lane: :crisis` and uses the
      # preconfigured crisis_message as the body. The TelegramOutbound
      # Worker job lives on the :telegram_outbound_crisis queue
      # (its declared queue).
      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{chat_id_hash: @chat_id_hash, lane: :crisis}
      )

      # No job on the safe-path queue.
      safe_jobs =
        Repo.all(
          from j in Oban.Job,
            where: j.queue == "telegram_outbound" and j.state == "scheduled"
        )

      assert safe_jobs == []
    end

    test "safe classification does NOT broadcast on 'psychologist:alerts'", ctx do
      _ = ctx
      Process.delete(:telegram_test_pid)

      # Subscribe in the test process (the setup :setup_bound_patient
      # runs in a different test context, so we re-subscribe here).
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("hola, buen día", telegram_message_id: 708, telegram_update_id: 78)
               })

      refute_receive {:crisis_detected, _}, 200

      # Regression: the legacy patient's urgent_intervention flag
      # must NOT have been set on the safe path.
      assert Alethea.Accounts.get_patient!(ctx.legacy_patient.id).urgent_intervention == false
    end
  end

  describe "perform/1 — crisis branch with a customized crisis_message" do
    setup :setup_bound_patient_with_custom_crisis_message

    test "uses the customized crisis_message in the outbound body and the diagnosis",
         ctx do
      _ = ctx

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a quitar la vida",
                     telegram_message_id: 800,
                     telegram_update_id: 80
                   )
               })

      outbound = Repo.one(from m in Message, where: m.direction == "outbound")
      assert decrypted_outbound_body(outbound) == "Custom reply from Dr. Test"

      inbound = Repo.one(from m in Message, where: m.direction == "inbound")
      diagnosis = Repo.one(from d in Alethea.AI.Diagnosis, where: d.message_id == ^inbound.id)
      assert diagnosis.ai_response == "Custom reply from Dr. Test"
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
    setup_bound_patient_with_crisis_message(nil)
  end

  defp setup_bound_patient_with_custom_crisis_message(_ctx) do
    setup_bound_patient_with_crisis_message("Custom reply from Dr. Test")
  end

  defp setup_bound_patient_with_crisis_message(crisis_message) do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{unique_int()}"})

    legacy_pro =
      insert_legacy_professional_with_crisis_message(
        crisis_message || "Estoy aquí para ayudarte. Llamame al 0800-..."
      )

    legacy_pat = insert_legacy_patient(legacy_pro, "alias-#{unique_int()}")

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: @chat_id_hash,
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    # Preload the professional on the legacy patient so the worker
    # can read `legacy_patient.professional.crisis_message` without
    # a follow-up DB hit.
    legacy_pat = Alethea.Accounts.get_patient_with_professional(legacy_pat.id)

    [
      foundation_patient: foundation_pat,
      legacy_patient: legacy_pat,
      chat_id_hash: @chat_id_hash
    ]
  end

  defp insert_legacy_professional_with_crisis_message(crisis_message) do
    {:ok, pro} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    # `create_professional` does not accept `crisis_message` in the
    # first-arg attrs (the changeset only casts email/password/full_name).
    # Update the row directly.
    pro
    |> Ecto.Changeset.change(%{crisis_message: crisis_message})
    |> Repo.update!()
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

  defp decrypted_outbound_body(%Message{} = message) do
    # Outbound messages are encrypted at rest via Clinical.save_message
    # (Cloak.Ecto + the legacy Patient's DEK). For the test to assert on
    # the body content we read it back through the same Clinical path
    # the production worker uses.
    {:ok, legacy_patient} =
      Alethea.Foundation.Accounts.legacy_patient(
        Alethea.Foundation.Accounts.Patient
        |> Repo.get_by!(legacy_patient_id: message.patient_id)
      )

    {:ok, dek} = Alethea.Clinical.patient_dek(legacy_patient)
    {:ok, plaintext} = Alethea.Clinical.decrypt_message_content(message, dek)
    plaintext
  end
end
