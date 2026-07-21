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
  import Mox

  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Clinical.Message
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, Client.Fake, Pacer}
  alias AletheaJobs.EmotionAnalysisWorker

  import Alethea.FoundationTestHelper
  import Ecto.Query

  # Inline test doubles for the LLM adapter were removed when the
  # safe path migrated from the `:ai_llm` discovery seam to the
  # `:phi_worker` Mox port. The setup-level
  # `Alethea.AI.PhiWorkerMock` `stub/2` below is now the only AI
  # pipeline mock — tests that need to drive a specific shape or an
  # error path use `expect(:process, ...)` to override the default
  # stub. `verify_on_exit!` (further down) fails the test if any
  # unexpected `PhiWorker.process/1` call lands.

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @unregistered_copy "Hola. No reconozco este chat en nuestro sistema clínico. Si eres un paciente, por favor contacta a tu terapeuta para que te registre."

  setup do
    # Pepper is required by `ChatIdHash.hash/2` (raises on < 32 bytes).
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    # Hermetic Oban queue state: every test starts with an empty
    # `oban_jobs` table so `assert_enqueued` does not pick up jobs from
    # other tests.
    Repo.delete_all(Oban.Job)

    # Pacer: hermetic per-test state, fast refill. The MessageWorkerTest
    # exercises the crisis lane queue-full escalation which calls
    # `TelegramOutboundWorker.perform_now/1` inline — that path
    # acquires a Pacer token. We start the Pacer here per test so the
    # acquire call does not exit with `noproc`.
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

    # Start the Telegram Client.Fake so the crisis escalation's
    # `TelegramOutboundWorker.perform_now/1` path can record the send.
    # The message worker test exercises the queue-full escalation
    # which invokes perform_now inline; that path calls `Fake.send_message/2`
    # via the configured `:telegram_client` adapter.
    start_supervised!(Alethea.Telegram.Client.Fake)
    Alethea.Telegram.Client.Fake.reset()
    Application.put_env(:alethea, :telegram_client, Alethea.Telegram.Client.Fake)

    # Mox setup for tests that stub `OutboundEnqueue.insert/1` to
    # simulate `:queue_full`.
    #
    # Default stub for `Alethea.AI.PhiWorkerMock.process/1`. Tests that
    # need to assert on the call shape (or drive an error path) override
    # this with `expect(:process, ...)`. Without this stub, every happy
    # path test would need to re-state the same default reply — and any
    # test that forgets to set one would fail with a Mox
    # UnexpectedCallError on the worker's `phi_worker().process/1` call.
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

    test "calls phi_worker().process/1 with the inbound message id, raw content, and patient context",
         ctx do
      args = build_args("hola, buen día", telegram_message_id: 302, telegram_update_id: 7)
      _ = ctx

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid, raw_content: text, patient_context: ctx_str} ->
        assert is_binary(mid)
        assert text == "hola, buen día"
        assert is_binary(ctx_str)

        {:ok,
         %{
           response: "respuesta clínica",
           source_message_id: mid,
           model_version: "phi-4-mini",
           behavior_type: :elicited
         }}
      end)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})
    end

    test "anchors the AI diagnosis to the inbound message (source_message_id == inbound.id)",
         ctx do
      args = build_args("hola, buen día", telegram_message_id: 303, telegram_update_id: 8)
      _ = ctx

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        {:ok,
         %{
           response: "respuesta clínica",
           source_message_id: mid,
           model_version: "phi-4-mini",
           behavior_type: :elicited
         }}
      end)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      inbound = Repo.one(from m in Message, where: m.direction == "inbound")
      assert inbound

      diagnosis = Repo.one(from d in Alethea.AI.Diagnosis, where: d.message_id == ^inbound.id)
      assert diagnosis
      assert diagnosis.model_version == "phi-4-mini"
      assert diagnosis.ai_response == "respuesta clínica"
    end

    test "safe path still feeds the sentiment pipeline (regression): enqueues " <>
           "EmotionAnalysisWorker for the inbound message and passes its id to PhiWorker",
         ctx do
      args = build_args("hola, buen día", telegram_message_id: 310, telegram_update_id: 31)
      _ = ctx

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        # Round 2 SEVERE fix: prove the worker actually forwards the
        # inbound message id to PhiWorker (not just any binary) — the
        # previous version of this test never asserted `mid ==
        # inbound.id`, so a regression that passed a stray id would
        # have gone undetected.
        send(self(), {:phi_worker_process_mid, mid})

        {:ok,
         %{
           response: "ok",
           source_message_id: mid,
           model_version: "phi-4-mini",
           behavior_type: :elicited
         }}
      end)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      inbound = Repo.one(from m in Message, where: m.direction == "inbound")

      assert_receive {:phi_worker_process_mid, mid}
      assert mid == inbound.id

      assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: inbound.id})
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
      args = build_args("hola", telegram_message_id: 500, telegram_update_id: 12)
      _ = ctx

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn _ -> {:error, :service_unavailable} end)

      assert_raise RuntimeError, ~r/service_unavailable/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      # The inbound persisted but no outbound was enqueued.
      assert Repo.aggregate(Message, :count) == 1
      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "empty PhiWorker response raises (fail-loud — no silent empty delivery)",
         ctx do
      args = build_args("hola", telegram_message_id: 501, telegram_update_id: 14)
      _ = ctx

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        {:ok,
         %{
           response: "",
           source_message_id: mid,
           model_version: "phi-4-mini",
           behavior_type: :elicited
         }}
      end)

      assert_raise RuntimeError, ~r/empty response/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      # The inbound persisted but no outbound was enqueued and no
      # empty Message row was created (the empty-response guard fires
      # before persist_and_enqueue_outbound).
      assert Repo.aggregate(Message, :count) == 1
      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "diagnosis-save failure raises BEFORE enqueueing TelegramOutboundWorker (no double-send on retry)",
         ctx do
      _ = ctx

      # Forcing function: stub PhiWorkerMock to return a `chain_result`
      # WITHOUT a `model_version` key. `Clinical.save_ai_diagnosis/2`
      # then sets `model_version: nil`, which fails the Diagnosis
      # changeset (`validate_required([:model_version, ...])`). The
      # worker's `with` chain therefore raises on the second step
      # BEFORE `enqueue_outbound/6` runs — the resolved ordering
      # guarantee (no double-send on Oban retry).
      args = build_args("hola", telegram_message_id: 600, telegram_update_id: 13)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        {:ok,
         %{
           response: "respuesta clínica",
           source_message_id: mid,
           # NB: no `model_version` key — `save_ai_diagnosis/2` will
           # coerce `Map.get(...)` to nil, and the Diagnosis
           # `validate_required(:model_version)` will reject it.
           behavior_type: :elicited
         }}
      end)

      assert_raise RuntimeError, ~r/failed to persist AI reply\/diagnosis/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      # Direct proof of the RESOLVED ordering: enqueue happens
      # STRICTLY after a successful diagnosis save. If the diagnosis
      # save fails, no TelegramOutboundWorker job is enqueued — so
      # an Oban retry cannot re-deliver a message the patient
      # already received (the previous attempt did NOT enqueue
      # because the diagnosis step raised first).
      refute_enqueued(worker: TelegramOutboundWorker)

      # Round 2 SEVERE fix (atomicity): the outbound Message insert
      # and the diagnosis insert now run inside a single
      # `Repo.transaction`. Before the fix, the outbound row committed
      # BEFORE the diagnosis save failed — leaving a fabricated
      # "elicited" outbound Message row permanently persisted (a
      # clinical record of a reply the patient never received, since
      # the job then raised and no TelegramOutboundWorker was
      # enqueued). Asserting 0 outbound rows proves the rollback.
      outbound_count =
        Repo.aggregate(from(m in Message, where: m.direction == "outbound"), :count)

      assert outbound_count == 0
    end

    test "diagnosis-save failure error message does NOT leak the plaintext AI reply " <>
           "(PHI hygiene, Round 2 SEVERE fix)",
         ctx do
      _ = ctx

      sentinel_reply = "SENTINEL-PHI-#{unique_int()}-mi terapeuta me dijo que..."

      args = build_args("hola", telegram_message_id: 601, telegram_update_id: 131)

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid} ->
        {:ok,
         %{
           response: sentinel_reply,
           source_message_id: mid,
           # NB: no `model_version` key, same forcing function as the
           # sibling test above — the diagnosis changeset rejects the
           # missing required field.
           behavior_type: :elicited
         }}
      end)

      error =
        assert_raise RuntimeError, fn ->
          TelegramMessageWorker.perform(%Oban.Job{args: args})
        end

      refute error.message =~ sentinel_reply,
             "the raised error message must not embed the plaintext AI reply " <>
               "(the full changeset `changes` map would leak it via inspect/1)"
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

    test "on :crisis classification, PhiWorkerMock.process/1 is NOT invoked (REQ-C5 scenario: never produces a neutral LLM reply)",
         ctx do
      _ = ctx

      text = "me voy a quitar la vida"

      # `verify_on_exit!` (already in the file's `setup`) fails the
      # test if any unexpected `Alethea.AI.PhiWorkerMock.process/1`
      # call lands. The crisis branch never calls `phi_worker()` —
      # it short-circuits through `handle_crisis_path/*`. The setup-
      # level stub is therefore allowed but never invoked.
      Alethea.AI.PhiWorkerMock
      |> expect(:process, 0, fn _ ->
        flunk("phi_worker().process/1 must NOT be invoked on the crisis path")
      end)

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args: build_args(text, telegram_message_id: 700, telegram_update_id: 70)
               })
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

      assert patient_id == ctx.foundation_patient.id,
             "Round 1 (WARNING-5): the :crisis_detected broadcast and the dead-letter " <>
               "row must carry the foundation patient UUID (the FK on " <>
               "foundation_outbound_dead_letters.patient_id requires the UUID)"

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
  # Crisis queue-full escalation (REQ-C7-crisis-queue-full-escalation;
  #                              PR #3b / TASK-3b-3)
  # ----------------------------------------------------------------

  describe "escalate_to_perform_now/2 — queue-full escalation (REQ-C7-crisis-queue-full-escalation)" do
    setup :setup_bound_patient

    setup do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "ops:alerts")
      :ok
    end

    test "broadcasts :crisis_queue_full on 'ops:alerts' AFTER perform_now with chat_id_hash, body_length, delivered, at" do
      # Round 1 (judgment-day, WARNING-6): the broadcast fires AFTER
      # `perform_now/1` and reflects the post-send outcome via the
      # `delivered` boolean — operator dashboards must NOT see a
      # "queue full" event for a send that ALREADY succeeded (they
      # would try to replay it and double-send to the patient).
      #
      # The payload intentionally omits `text: body` (PHI hygiene —
      # the outbound body is the psychologist's preconfigured
      # `crisis_message`; operators don't need it in an alert). Only
      # `body_length` is included as a diagnostic signal.
      args = %{
        chat_id_hash: @chat_id_hash,
        chat_id: 987_654_321,
        message_id: nil,
        body: "hola, buen día",
        lane: :crisis
      }

      hash_prefix = String.slice(@chat_id_hash, 0, 8)

      assert :ok = TelegramMessageWorker.escalate_to_perform_now(args, hash_prefix)

      assert_receive {:crisis_queue_full,
                      %{
                        chat_id_hash: chat_id_hash,
                        body_length: body_length,
                        delivered: delivered,
                        at: at
                      }},
                     1_000

      assert chat_id_hash == @chat_id_hash
      assert body_length == byte_size("hola, buen día")
      assert delivered == true, "the inline send succeeded — delivered: true"
      assert is_struct(at, DateTime)
    end

    test "broadcasts delivered: false when perform_now dead-letters (operator replays manually)" do
      # Companion test for WARNING-6: when perform_now itself fails
      # (e.g., the Fake queue is exhausted), the broadcast must carry
      # `delivered: false` so the operator knows to replay manually
      # instead of reacting to a "queue full" event as if the send
      # were still pending.
      args = %{
        chat_id_hash: @chat_id_hash,
        chat_id: 987_654_321,
        message_id: nil,
        body: "crisis message that will fail",
        lane: :crisis,
        patient_id: nil
      }

      # Queue a permanent failure for the Fake.
      Fake.queue_responses([{:error, :network}])

      hash_prefix = String.slice(@chat_id_hash, 0, 8)

      assert :ok = TelegramMessageWorker.escalate_to_perform_now(args, hash_prefix)

      assert_receive {:crisis_queue_full,
                      %{
                        chat_id_hash: _,
                        body_length: _,
                        delivered: delivered,
                        at: _
                      }},
                     1_000

      assert delivered == false,
             "perform_now dead-lettered (no queue to retry through); delivered: false"
    end

    test "the spawned perform_now/1 still calls Pacer.acquire/1 before sending (REQ-C7-crisis-queue-full-escalation scenario 'Pacer safety net')" do
      # Use a unique chat hash so we can inspect its Pacer bucket
      # without interference from other tests.
      unique_chat_hash = "9" |> String.duplicate(64)

      args = %{
        chat_id_hash: unique_chat_hash,
        chat_id: 123_456_789,
        message_id: nil,
        body: "hola",
        lane: :crisis
      }

      pacer_before = Pacer.inspect_per_chat()

      assert :ok = TelegramMessageWorker.escalate_to_perform_now(args, "9" |> String.duplicate(8))

      pacer_after = Pacer.inspect_per_chat()

      # The Pacer per-chat bucket drained during perform_now.
      before_tokens = Map.get(pacer_before, unique_chat_hash, %{tokens: 1}).tokens
      after_tokens = Map.get(pacer_after, unique_chat_hash, %{tokens: 0}).tokens

      assert before_tokens == 1, "Pacer should start full for #{unique_chat_hash}"
      assert after_tokens == 0, "Pacer should be drained after perform_now (rate-limit bypass)"
    end

    test "on crisis lane queue_full from Oban.insert, the worker escalates to perform_now and broadcasts :crisis_queue_full (integration)" do
      # Stub the OutboundEnqueue adapter to return `:queue_full` for
      # crisis outbound. The emotion analysis enqueue still goes
      # through `Oban.insert/1` directly (unaffected by this stub),
      # so we can assert it lands.
      Mox.defmock(
        FailingQueueEnqueue,
        for: Alethea.Telegram.OutboundEnqueue
      )

      Mox.stub(FailingQueueEnqueue, :insert, fn _ ->
        {:error, :queue_full}
      end)

      Application.put_env(
        :alethea,
        :telegram_outbound_enqueue,
        FailingQueueEnqueue
      )

      on_exit(fn ->
        Application.delete_env(:alethea, :telegram_outbound_enqueue)
      end)

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a suicidar",
                     telegram_message_id: 900,
                     telegram_update_id: 90
                   )
               })

      # The escalation broadcast fires.
      assert_receive {:crisis_queue_full, %{chat_id_hash: _, delivered: _, at: _}}, 1_000

      # The inbound message was persisted (the inbound step succeeds
      # before the outbound enqueue).
      inbound = Repo.one(from m in Message, where: m.direction == "inbound")
      assert inbound

      # The emotion worker IS enqueued (this insert goes through the
      # real `Oban.insert/1`, not the stubbed OutboundEnqueue — only
      # the crisis outbound is mocked).
      assert_enqueued(worker: EmotionAnalysisWorker)
    end
  end

  # ----------------------------------------------------------------
  # Crisis end-to-end integration scenarios (REQ-C5 + REQ-C7;
  #                                     PR #3b / TASK-3b-6)
  # ----------------------------------------------------------------

  describe "perform/1 — crisis end-to-end integration scenarios (REQ-C5 + REQ-C7)" do
    # Use the existing wrapper that sets up a bound patient with a
    # customized crisis_message ("Custom reply from Dr. Test"). The
    # integration tests don't need a specific message string — they
    # assert on whatever was configured.
    setup :setup_bound_patient_with_custom_crisis_message

    setup do
      # Subscribe to BOTH pubsub topics: "psychologist:alerts" (per-spec
      # REQ-C5-crisis-broadcasts-alert) and "ops:alerts" (TASK-3b-3 +
      # TASK-3b-4 dead-letter broadcasts).
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")
      Phoenix.PubSub.subscribe(Alethea.PubSub, "ops:alerts")

      # Reset the OutboundEnqueue adapter to the default (real
      # Oban.insert). Other tests in this module may have set it to a
      # Mox stub via `Application.put_env(:alethea,
      # :telegram_outbound_enqueue, ...)`; we don't want that to leak
      # into these integration scenarios.
      Application.delete_env(:alethea, :telegram_outbound_enqueue)

      :ok
    end

    test "happy path: inbound crisis → outbound enqueued on crisis queue → perform_now-like execution records the send via Fake (REQ-C5 + REQ-C7 end-to-end story)",
         ctx do
      _ = ctx

      # 1. The Fake returns a successful send (no queue_responses set → default).
      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a suicidar",
                     telegram_message_id: 1000,
                     telegram_update_id: 100
                   )
               })

      # 2. Verify the outbound was enqueued on the crisis lane.
      [job] =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Alethea.Jobs.TelegramOutboundWorker" and
                j.queue == "telegram_outbound_crisis",
            limit: 1
        )

      assert job.args["lane"] == "crisis",
             "outbound was enqueued on the crisis queue with lane: :crisis"

      assert job.args["patient_id"] == ctx.foundation_patient.id,
             "patient_id is forwarded in args (TASK-3b-4 prerequisite for :crisis_dead_letter; " <>
               "Round 1 WARNING-5: the FK on foundation_outbound_dead_letters.patient_id requires the foundation UUID)"

      # 3. Simulate Oban dequeueing the job and the OutboundWorker
      # performing it. This is what Oban does at runtime — the test
      # exercises the same code path.
      before_snapshot = Pacer.inspect_per_chat()

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: job.args,
                 attempt: 1,
                 priority: 1
               })

      # 4. Pacer was acquired (rate-limit safety net preserved end-to-end).
      after_snapshot = Pacer.inspect_per_chat()
      before_tokens = Map.get(before_snapshot, @chat_id_hash, %{tokens: 1}).tokens
      after_tokens = Map.get(after_snapshot, @chat_id_hash, %{tokens: 0}).tokens

      assert before_tokens == 1, "Pacer should start full for #{@chat_id_hash}"
      assert after_tokens == 0, "Pacer should be drained after the crisis send"

      # 5. The Fake recorded the send with the crisis-bypass body.
      sends = Fake.sends()
      assert length(sends) == 1
      assert hd(sends).chat_id == @chat_id
      assert hd(sends).text == ctx.legacy_patient.professional.crisis_message

      # 6. No emotion analysis was blocked — the inbound worker enqueued
      # it BEFORE the crisis branch fired (REQ-C5-trigger-emotion-analysis).
      assert_enqueued(worker: EmotionAnalysisWorker)
    end

    test "crisis retry: error → reschedule on the crisis lane → success on 2nd attempt (REQ-C7-crisis-priority-lane: lane preserved across retries)",
         ctx do
      _ = ctx

      Fake.queue_responses([{:error, {:rate_limited, 1}}, {:ok, 1_234_567}])

      # 1. Inbound worker enqueues the crisis outbound.
      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a matar",
                     telegram_message_id: 1001,
                     telegram_update_id: 101
                   )
               })

      # 2. First perform attempt: error → reschedule.
      [first_job] =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Alethea.Jobs.TelegramOutboundWorker" and
                j.queue == "telegram_outbound_crisis",
            limit: 1
        )

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: first_job.args,
                 attempt: 1,
                 priority: 1
               })

      # 3. Rescheduled job stays on the crisis lane (lane preserved).
      # The rescheduled job is in state "scheduled" (scheduled_at is in
      # the future) and has a higher id than the original (which was
      # marked completed by perform/1).
      [second_job] =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Alethea.Jobs.TelegramOutboundWorker" and
                j.state == "scheduled",
            order_by: [desc: :id],
            limit: 1
        )

      assert second_job.args["lane"] == "crisis",
             "the retry was re-enqueued on the crisis lane (not the safe lane)"

      assert second_job.args["_attempt"] == 2

      # 4. Second perform attempt: success.
      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: second_job.args,
                 attempt: 2,
                 priority: 1
               })

      # 5. The send happened exactly once (the error didn't record).
      sends = Fake.sends()
      assert length(sends) == 1
      assert hd(sends).text == ctx.legacy_patient.professional.crisis_message
    end

    test "crisis exhaustion: 5 failures → :crisis_dead_letter broadcast (TASK-3b-4 clinical-incident signal) with patient_id from args",
         ctx do
      _ = ctx

      # Queue 5 consecutive errors. Each perform call consumes one
      # from the head.
      Fake.queue_responses(Enum.map(1..5, fn _ -> {:error, {:rate_limited, 1}} end))

      # Round 1 (WARNING-5): the `ctx.foundation_patient` is already
      # inserted by `setup_bound_patient/0`. The dead-letter FK to
      # `foundation_patients.id` resolves. No extra setup needed.

      # Inbound worker enqueues the crisis outbound.
      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args:
                   build_args("me voy a quitar la vida",
                     telegram_message_id: 1002,
                     telegram_update_id: 102
                   )
               })

      # Drive the 5 attempts: attempts 1-4 reschedule; attempt 5 hits
      # the exhaustion branch (dead-letter + :crisis_dead_letter broadcast).
      # We track the latest rescheduled job's args by id (desc) — the
      # original outbound job stays in state "scheduled" because we
      # call perform/1 directly (Oban doesn't transition state in
      # direct calls), so a naive "oldest scheduled" query would
      # repeatedly pick up the original.
      Enum.each(1..5, fn attempt ->
        job =
          Repo.one!(
            from j in Oban.Job,
              where: j.worker == "Alethea.Jobs.TelegramOutboundWorker",
              order_by: [desc: :id],
              limit: 1
          )

        TelegramOutboundWorker.perform(%Oban.Job{
          args: job.args,
          attempt: attempt,
          priority: 1
        })
      end)

      # 6. The clinical-incident broadcast fires with the patient_id
      # (TASK-3b-4 operator-visibility surface).
      assert_receive {:crisis_dead_letter,
                      %{
                        patient_id: patient_id,
                        chat_id_hash: chat_id_hash,
                        text: _,
                        error: _,
                        attempts: 5,
                        at: _
                      }},
                     1_000

      assert patient_id == ctx.foundation_patient.id,
             "the crisis dead-letter broadcast carries the foundation patient_id"

      assert chat_id_hash == @chat_id_hash

      # 7. A dead-letter row was written with attempts: 5.
      dl = Repo.one(Alethea.Foundation.Accounts.OutboundDeadLetter)
      assert dl
      assert dl.attempts == 5
      assert dl.chat_id_hash == @chat_id_hash

      # 8. The generic :outbound_dead_letter also fires (existing PR #3a
      # behavior — both events coexist on crisis dead-letter). The
      # `lane` field comes back as a string ("crisis") after the JSON
      # round-trip through Oban args (Oban serializes args to JSONB and
      # atoms → strings on read-back).
      assert_receive {:outbound_dead_letter, %{lane: lane, attempts: 5}}, 1_000
      assert lane in [:crisis, "crisis"]

      # 9. The dead-letter row's `attempts: 5` (verified above) confirms
      # the worker stopped retrying after @max_attempts — no further
      # Oban job was inserted in the dead-letter branch. (We don't
      # assert on `Oban.Job` row counts because direct `perform/1`
      # calls don't transition state — the rescheduled jobs from
      # iterations 1-4 stay in state "scheduled", which is an Oban
      # testing-mode artifact, not a behavior assertion.)
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
