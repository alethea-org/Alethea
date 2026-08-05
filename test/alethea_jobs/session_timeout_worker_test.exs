defmodule AletheaJobs.SessionTimeoutWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Alethea.{Accounts, Repo}
  alias Alethea.Clinical.{Session, SessionManager, Summary, Trend}
  alias Alethea.Jobs.TelegramOutboundWorker
  alias AletheaJobs.SessionTimeoutWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "timeout_test_#{:rand.uniform(999_999)}@example.com",
        password: "securepassword123",
        full_name: "Timeout Tester"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "whatsapp_number" => "+54110000000#{:rand.uniform(99)}",
          "alias" => "Test Patient",
          "professional_id" => professional.id
        },
        kek
      )

    {:ok, _} = Accounts.update_patient_terms(patient, true)
    patient = Accounts.get_patient!(patient.id)

    {:ok, session} = SessionManager.open_session(patient)

    {:ok, _message} =
      Alethea.Clinical.save_message(
        patient,
        "Me siento bien hoy",
        nil,
        "inbound",
        "spontaneous",
        nil,
        session.id
      )

    phone = "+54110000000#{:rand.uniform(99)}"

    %{patient: patient, session: session, phone: phone}
  end

  # #87: the WhatsApp path is retired. The channel-neutral goodbye send +
  # the legacy `%{phone: ...}` perform clause were removed. A timeout job
  # scheduled before the retirement (legacy WhatsApp args shape) must resolve
  # to a no-op via the orphan-safe fallback clause — no crash, no close flow.
  test "ignores a legacy WhatsApp (phone-args) timeout job without crashing", %{
    patient: patient,
    session: session,
    phone: phone
  } do
    log =
      capture_log(fn ->
        assert :ok =
                 perform_job(SessionTimeoutWorker, %{
                   session_id: session.id,
                   patient_id: patient.id,
                   phone: phone
                 })
      end)

    assert log =~ "ignoring non-Telegram timeout job"

    # The close flow did not run: no trends, no summary, session stays open.
    assert Repo.all(from(t in Trend, where: t.patient_id == ^patient.id)) == []
    assert Repo.all(from(s in Summary, where: s.patient_id == ^patient.id)) == []
    assert Repo.get!(Session, session.id).status == "open"
  end

  # ----------------------------------------------------------------
  # PR-1 (#86) — channel-neutral dispatch (Phase 1 RED).
  # Telegram channel enqueues a TelegramOutboundWorker goodbye job
  # (patient_id: nil — goodbyes are nil-safe per design). The 2
  # WhatsApp tests above remain unchanged.
  # ----------------------------------------------------------------

  describe "channel dispatch (PR-1 #86)" do
    setup do
      # Telegram args: no `phone`, instead `channel: "telegram"` with
      # the raw chat_id (never persisted at rest — only the HMAC hash
      # survives in storage) + the chat_id_hash for the rate-limit
      # Pacer key.
      chat_id = 987_654_321

      %{
        chat_id: chat_id,
        telegram_args: %{
          session_id: nil,
          patient_id: nil,
          channel: "telegram",
          chat_id: chat_id,
          chat_id_hash: "test_chat_id_hash_abcdef"
        }
      }
    end

    test "telegram-channel args enqueue TelegramOutboundWorker goodbye (chat_id, chat_id_hash, body, patient_id: nil)",
         %{session: session, patient: patient, telegram_args: targs} do
      targs = %{targs | session_id: session.id, patient_id: patient.id}

      emotion_scores = [
        %{label: "joy", score: 0.80},
        %{label: "sadness", score: 0.05},
        %{label: "anger", score: 0.05},
        %{label: "fear", score: 0.05},
        %{label: "neutral", score: 0.05}
      ]

      Alethea.AI.RoBERTaWorkerMock
      |> expect(:analyze_batch, fn _texts -> emotion_scores end)

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        {:ok, "1. Estado: alegre\n2. Temas: trabajo\n3. Cambios: mejora\n4. Estable"}
      end)

      assert :ok = perform_job(SessionTimeoutWorker, targs)

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{
          chat_id: 987_654_321,
          chat_id_hash: "test_chat_id_hash_abcdef",
          patient_id: nil
        }
      )

      # Body content check: pull the enqueued job's args directly from
      # the DB so we can assert on the goodbye body without having to
      # bind a variable inside the `assert_enqueued` macro context.
      [job] =
        Repo.all(from j in Oban.Job, where: j.worker == "Alethea.Jobs.TelegramOutboundWorker")

      assert job.args["body"] =~ "Tu sesión de hoy ha concluido"
    end

    test "telegram-channel idempotent skip: closed session short-circuits, NO TelegramOutboundWorker enqueued",
         %{session: session, patient: patient, telegram_args: targs} do
      {:ok, _} = SessionManager.close_session(session)

      targs = %{targs | session_id: session.id, patient_id: patient.id}

      # Neither adapter should be invoked — any unexpected call
      # indicates the close-skip guard failed.
      Alethea.AI.RoBERTaWorkerMock
      |> expect(:analyze_batch, 0, fn _ -> flunk("RoBERTa must not run on closed session") end)

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, 0, fn _, _ ->
        flunk("SessionSummaryChain must not run on closed session")
      end)

      assert :ok = perform_job(SessionTimeoutWorker, targs)

      refute_enqueued(worker: TelegramOutboundWorker)
    end
  end

  # ----------------------------------------------------------------
  # R2 (#86 PR-1) — PHI-safe error rendering.
  #
  # Background: the worker's `run_close_flow/3` `else` branch (the
  # single error sink for the summary / trends / etc pipeline) used
  # to call `inspect(reason)` directly on the failure. When the
  # failure was an `Ecto.Changeset` (e.g. `Clinical.save_summary/1`
  # returning `{:error, %Ecto.Changeset{changes: %{summary_text: ...}}}`),
  # the inspect output embedded the full `changes` map — which for
  # `Alethea.Clinical.Summary` carries `summary_text` (the
  # AI-generated clinical summary) + `patient_id`. Same class of bug
  # as the #85 R1 fix on `TelegramMessageWorker` (MatchError on
  # Changeset leaking PHI via Oban `errors` column). The R2 fix
  # applies `AletheaJobs.SafeReason.for_log/1` at the Logger.error
  # site; this test pins the contract.
  # ----------------------------------------------------------------

  describe "PHI-safe error rendering (R2 #86 PR-1 fix)" do
    # The sentinel is the value we inject into the failing Changeset's
    # `changes` map. After the worker logs the error, we assert this
    # sentinel string does NOT appear in the captured log — the
    # helper must render only the failed-validation field keys, never
    # the `changes` map (which is the PHI surface).
    @phi_sentinel "FAKE-CLINICAL-SUMMARY-MUST-NOT-LEAK-IN-LOGS-ABCD1234"

    test "failed save_summary: log line contains only the failed validation keys, NEVER the summary_text from changes",
         %{
           patient: patient,
           session: session
         } do
      emotion_scores = [
        %{label: "joy", score: 0.80},
        %{label: "sadness", score: 0.05},
        %{label: "anger", score: 0.05},
        %{label: "fear", score: 0.05},
        %{label: "neutral", score: 0.05}
      ]

      Alethea.AI.RoBERTaWorkerMock
      |> expect(:analyze_batch, fn _texts -> emotion_scores end)

      # Force `Clinical.save_summary/1` to fail by piping a Changeset
      # with a violation through the chain. The chain itself returns
      # the failing shape (the worker's `with` pattern catches
      # `{:error, _}` uniformly — the `else` branch doesn't care
      # which step emitted the changeset).
      #
      # The mock builds the failing Changeset via the real
      # `Summary.changeset/2`, so the test exercises the actual
      # changeset shape that `save_summary/1` would emit — not a
      # hand-rolled struct. The `summary_text` is set to the sentinel
      # so we can grep for it in the captured log.
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        failing_cs =
          %Summary{}
          |> Summary.changeset(%{
            period_start: DateTime.utc_now(),
            period_end: DateTime.utc_now(),
            # SENTINEL: this value MUST NOT appear in the captured log.
            summary_text: @phi_sentinel,
            status_level: nil,
            type: "session",
            patient_id: patient.id
          })

        # `status_level: nil` triggers `validate_required(:status_level)`.
        # `changes.summary_text` still carries the sentinel — the
        # worker MUST NOT embed that value in the Logger.error line.
        {:error, failing_cs}
      end)

      log =
        capture_log([level: :error], fn ->
          result =
            perform_job(SessionTimeoutWorker, %{
              session_id: session.id,
              patient_id: patient.id,
              channel: "telegram",
              chat_id: 987_654_321,
              chat_id_hash: "test_chat_id_hash_abcdef"
            })

          # The worker MUST surface the failure to Oban so Oban
          # retries up to its configured max_attempts (the worker is
          # `max_attempts: 3`). `perform_job` returns the raw
          # return value.
          assert {:error, _reason} = result
        end)

      # Direct PHI non-leak assertion. The sentinel string is in
      # `changes.summary_text`; `inspect/1` on the Changeset WOULD
      # embed it. `SafeReason.for_log/1` MUST NOT.
      refute log =~ @phi_sentinel,
             "PHI leaked into Logger.error line via inspect(reason) on an Ecto.Changeset — " <>
               "sentinel appeared in: #{inspect(log)}"

      # The log SHOULD surface the failed-validation field key (the
      # safe rendering — `:status_level` is the field that fails
      # `validate_required`). This proves the helper ran, not a
      # silent no-op.
      assert log =~ "SessionTimeoutWorker failed for session #{session.id}",
             "expected the worker to log the failure at error level; got: #{inspect(log)}"

      assert log =~ "[:status_level]",
             "expected the log to render the failed-validation field key as `[:status_level]`; " <>
               "got: #{inspect(log)}"
    end

    test "failed save_summary with summary_text in the changes map: the summary_text value MUST NOT appear in the log",
         %{
           patient: patient,
           session: session
         } do
      emotion_scores = [
        %{label: "joy", score: 0.80},
        %{label: "sadness", score: 0.05},
        %{label: "anger", score: 0.05},
        %{label: "fear", score: 0.05},
        %{label: "neutral", score: 0.05}
      ]

      Alethea.AI.RoBERTaWorkerMock
      |> expect(:analyze_batch, fn _texts -> emotion_scores end)

      # Force save_summary failure on a DIFFERENT field (`:type`) so
      # the failed-validation key is `[:type]`. The `summary_text` is
      # still in `changes` (the successful cast) — this isolates the
      # `changes`-vs-`errors` rendering of the helper, which is the
      # exact contract.
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        failing_cs =
          %Summary{}
          |> Summary.changeset(%{
            period_start: DateTime.utc_now(),
            period_end: DateTime.utc_now(),
            # SENTINEL — still embedded in `changes`.
            summary_text: @phi_sentinel,
            status_level: "Estable",
            # Wrong type — fails `validate_inclusion(:type, ["session", "weekly"])`.
            type: "made_up_type_xyz",
            patient_id: patient.id
          })

        {:error, failing_cs}
      end)

      log =
        capture_log([level: :error], fn ->
          assert {:error, _} =
                   perform_job(SessionTimeoutWorker, %{
                     session_id: session.id,
                     patient_id: patient.id,
                     channel: "telegram",
                     chat_id: 987_654_321,
                     chat_id_hash: "test_chat_id_hash_abcdef"
                   })
        end)

      # The exact contract that fails without the fix.
      refute log =~ @phi_sentinel,
             "summary_text value (PHI) leaked via Logger.error — " <>
               "sentinel appeared in: #{inspect(log)}"

      assert log =~ "[:type]",
             "expected the log to render `[:type]`; got: #{inspect(log)}"
    end
  end
end
