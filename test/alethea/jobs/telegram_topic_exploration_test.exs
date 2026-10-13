defmodule Alethea.Jobs.TelegramTopicExplorationTest do
  @moduledoc """
  Worker-entry tests for the exploration wiring (#393 S3): driven
  through `Alethea.Jobs.TelegramMessageWorker.perform/1` and the armed
  `Alethea.Jobs.TelegramBurstReplyWorker`, with `Alethea.AI.PhiWorkerMock`
  returning marker-prefixed canned text — simulating what #393 S4's
  prompt will eventually cause the real model to emit. No live model.

  Covers (design "Testing Strategy", worker entry row; tasks.md 3.3):
  the question-count progression `0->1` and `2->3`; a missing marker
  still counting toward the limit instead of resetting it; the closing
  invitation substituted once the limit is reached; the post-closing
  acknowledgement; the marker never reaching the persisted row, the
  delivery job, or `ai_diagnoses.ai_response`; a guard-triggered
  fallback counting and, at the limit, itself being replaced by
  closing copy; and `exploration_mode` in the AI worker payload.

  NUEVO resets, the crisis/session resets, the multi-topic burst, and
  the retry-after-rollback scenario are #393 S4 (tasks.md Phase 4) —
  out of scope here.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox
  import Ecto.Query
  import Alethea.FoundationTestHelper

  alias Alethea.Clinical
  alias Alethea.Clinical.{Message, SessionManager}
  alias Alethea.Jobs.{TelegramBurstReplyWorker, TelegramMessageWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, JournalingFallback}
  alias AletheaJobs.EmotionAnalysisWorker

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 393_393_393
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)
    setup_bound_patient()
  end

  setup :verify_on_exit!

  describe "perform/1 — question-count progression" do
    # Trim lever (task 3.7): every row shares the same shape — an
    # optional prior counted reply, a model reply, and the expected
    # persisted exploration state plus the `exploration_mode` sent to
    # the model for that turn (design §3's four-row table + the
    # "Missing marker" scenario from spec.md).
    for {label, prior, raw_reply, expected_mode, expected_questions, expected_sent,
         expected_response} <- [
          {"first question of a stretch becomes count 1", nil, "<<SIGUE>>\n¿Qué sentiste?", :open,
           1, false, {:text, "¿Qué sentiste?"}},
          {"a continuing question raises count 2 to 3", {2, false}, "<<SIGUE>>\n¿Y después?",
           :open, 3, false, {:text, "¿Y después?"}},
          {"a missing marker still counts toward the limit instead of resetting it", {2, false},
           "¿Qué pasó?", :open, 3, false, {:text, "¿Qué pasó?"}},
          {"a fourth question at the limit becomes the closing invitation", {3, false},
           "<<SIGUE>>\n¿Qué más pasó?", :closing, 3, true, :closing},
          {"a question after the invitation becomes the acknowledgement", {3, true},
           "<<SIGUE>>\nGracias, ¿cómo te fue?", :closing, 3, true, :acknowledgement}
        ] do
      test label, ctx do
        prior = unquote(prior)
        expected_response = unquote(expected_response)

        session = open_session(ctx)
        maybe_seed_prior(ctx, session, prior)

        result = perform_scenario(ctx, unquote(raw_reply), unique_n())

        assert result.request.exploration_mode == unquote(expected_mode)
        assert result.reply.exploration_questions == unquote(expected_questions)
        assert result.reply.closing_invitation_sent == unquote(expected_sent)
        assert_expected_response(result.persisted_body, expected_response)
      end
    end
  end

  describe "perform/1 — marker hygiene across every storage location" do
    test "the marker never reaches the persisted row, the delivery job, or ai_diagnoses", ctx do
      result = perform_scenario(ctx, "<<SIGUE>>\n¿Qué sentiste en ese momento?", unique_n())

      assert result.persisted_body == "¿Qué sentiste en ese momento?"
      assert result.job_body == result.persisted_body
      assert result.diagnosis_response == result.persisted_body
      refute result.diagnosis_response =~ "<<"

      assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: result.inbound.id})
    end
  end

  describe "perform/1 — guard fallback and the exploration limit" do
    test "a blocked diagnostic reply's fallback still counts as a question", ctx do
      session = open_session(ctx)
      maybe_seed_prior(ctx, session, {1, false})

      blocked = "<<SIGUE>>\nPor lo que describes, parece un trastorno de ansiedad."
      result = perform_scenario(ctx, blocked, unique_n())

      refute result.persisted_body =~ "trastorno"
      assert result.reply.exploration_questions == 2
      refute result.reply.closing_invitation_sent
    end

    test "at the limit, the guard's own fallback is itself replaced by closing copy", ctx do
      session = open_session(ctx)
      maybe_seed_prior(ctx, session, {3, false})

      blocked = "<<SIGUE>>\nTe recomiendo iniciar terapia."
      result = perform_scenario(ctx, blocked, unique_n())

      refute result.persisted_body =~ "recomiendo"
      assert result.persisted_body in JournalingFallback.closing_invitations()
      assert result.reply.exploration_questions == 3
      assert result.reply.closing_invitation_sent
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp assert_expected_response(actual, {:text, text}), do: assert(actual == text)

  defp assert_expected_response(actual, :closing),
    do: assert(actual in JournalingFallback.closing_invitations())

  defp assert_expected_response(actual, :acknowledgement),
    do: assert(actual in JournalingFallback.acknowledgements())

  defp open_session(ctx) do
    {:ok, session} = SessionManager.current_open_session(ctx.legacy_patient.id)
    session
  end

  defp maybe_seed_prior(_ctx, _session, nil), do: :ok

  # Seeds a settled (`delivery_state: "sent"`) prior outbound reply in
  # `session`, backdated so it unambiguously precedes the scenario's
  # own inbound, and covers its own anchor inbound so neither
  # `uncovered_inbound?/1` nor `list_burst_members/1` folds it into
  # the new burst (design's test-setup note).
  defp maybe_seed_prior(ctx, session, {questions, closing_invitation_sent}) do
    {:ok, prior_inbound} =
      Clinical.save_telegram_message(
        ctx.foundation_patient,
        "previo",
        "inbound",
        "spontaneous",
        "prior-#{unique_n()}",
        session.id
      )

    {:ok, prior_reply} =
      Clinical.save_telegram_reply(
        ctx.foundation_patient,
        "respuesta previa",
        "elicited",
        prior_inbound.id,
        session.id,
        %{exploration_questions: questions, closing_invitation_sent: closing_invitation_sent}
      )

    1 = Clinical.cover_members([prior_inbound.id], prior_reply.id)

    past = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(m in Message, where: m.id == ^prior_reply.id),
      set: [delivery_state: "sent", timestamp: past]
    )

    :ok
  end

  # Runs one inbound through the real worker chain, drives the armed
  # burst-reply job, and returns everything a test might assert on.
  defp perform_scenario(ctx, raw_reply, n) do
    test_pid = self()

    expect(Alethea.AI.PhiWorkerMock, :process, fn request ->
      send(test_pid, {:request, request})
      {:ok, ai_result(request.message_id, raw_reply)}
    end)

    assert :ok =
             TelegramMessageWorker.perform(%Oban.Job{
               args: build_args(n, "mensaje del paciente")
             })

    assert :ok = run_burst_reply()
    assert_receive {:request, request}

    inbound = Repo.one!(from m in Message, where: m.telegram_message_id == ^to_string(n))
    reply = Repo.get!(Message, inbound.replied_by_message_id)
    [job] = all_enqueued(worker: TelegramOutboundWorker)
    diagnosis = Repo.one!(from d in Alethea.AI.Diagnosis, where: d.message_id == ^inbound.id)

    %{
      request: request,
      inbound: inbound,
      reply: reply,
      persisted_body: decrypted_body(ctx, reply),
      job_body: job.args["body"],
      diagnosis_response: diagnosis.ai_response
    }
  end

  defp run_burst_reply do
    [job] = all_enqueued(worker: TelegramBurstReplyWorker)
    TelegramBurstReplyWorker.perform(%Oban.Job{args: job.args})
  end

  defp ai_result(message_id, response) do
    %{
      response: response,
      source_message_id: message_id,
      model_version: "phi-4-mini",
      behavior_type: :elicited
    }
  end

  defp decrypted_body(ctx, %Message{} = message) do
    {:ok, dek} = Clinical.patient_dek(ctx.legacy_patient)
    {:ok, plaintext} = Clinical.decrypt_message_content(message, dek)
    plaintext
  end

  defp build_args(n, text) do
    %{
      "telegram_update_id" => n,
      "message" => %{
        "message_id" => n,
        "date" => 1_700_000_000,
        "chat" => %{"id" => @chat_id, "type" => "private"},
        "text" => text
      }
    }
  end

  defp unique_n, do: System.unique_integer([:positive])

  defp setup_bound_patient do
    foundation_patient = patient_fixture(professional_fixture(), %{alias: "Pat#{unique_n()}"})

    {:ok, legacy_professional} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_n()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_n()}"
      })

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_professional)

    {:ok, legacy_patient} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_n()}", "professional_id" => legacy_professional.id},
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
end
