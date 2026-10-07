defmodule AletheaJobs.SessionTimeoutWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Alethea.{Accounts, Repo}
  alias Alethea.AI.EmotionAnalyzer
  alias Alethea.Clinical.{Session, SessionManager, Summary, Trend}
  alias Alethea.Jobs.TelegramOutboundWorker
  alias AletheaJobs.SessionTimeoutWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  # Issue #198 — the :emotion_analyzer slot is wired to
  # Alethea.AI.EmotionAnalyzer.Fake in config/test.exs by default.
  # The Fake returns a fixed canonical vector (joy=0.8 dominant) — the
  # happy-path tests below rely on that shape. The failure-shape tests
  # swap in the EmotionAnalyzerBehaviourMock so the failure branches
  # are exercised with deliberate, deterministic inputs.
  setup do
    previous_analyzer = Application.get_env(:alethea, :emotion_analyzer)

    on_exit(fn ->
      if previous_analyzer do
        Application.put_env(:alethea, :emotion_analyzer, previous_analyzer)
      else
        Application.delete_env(:alethea, :emotion_analyzer)
      end
    end)

    :ok
  end

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
        session.id
      )

    phone = "+54110000000#{:rand.uniform(99)}"

    %{patient: patient, session: session, phone: phone}
  end

  # #87: the WhatsApp path is retired. A timeout job scheduled before the
  # retirement (legacy `%{phone: ...}` args) still closes + summarizes the
  # session — the close/summary/trends pipeline is channel-independent — but
  # SKIPS the retired WhatsApp goodbye (routed to the unknown-channel
  # backstop), so no TelegramOutboundWorker goodbye is enqueued.
  test "closes and summarizes a legacy WhatsApp (phone-args) session, skipping the retired goodbye",
       %{patient: patient, session: session, phone: phone} do
    # Issue #198 — the :emotion_analyzer slot is wired to
    # Alethea.AI.EmotionAnalyzer.Fake in config/test.exs (deterministic
    # joy=0.8 dominant). No explicit mock expectation needed.

    Alethea.AI.SessionSummaryChainMock
    |> expect(:run, fn _texts, _scores ->
      {:ok, "1. Estado: alegre\n2. Temas: trabajo\n3. Cambios: mejora\n4. Estable"}
    end)

    log =
      capture_log(fn ->
        assert :ok =
                 perform_job(SessionTimeoutWorker, %{
                   session_id: session.id,
                   patient_id: patient.id,
                   phone: phone
                 })
      end)

    # The close flow ran: session closed, trends + summary persisted.
    assert Repo.get!(Session, session.id).status == "closed"
    assert length(Repo.all(from(t in Trend, where: t.patient_id == ^patient.id))) == 5
    assert length(Repo.all(from(s in Summary, where: s.patient_id == ^patient.id))) == 1

    # The retired WhatsApp goodbye is skipped via the unknown-channel
    # backstop; no Telegram goodbye is enqueued for a legacy WhatsApp session.
    assert log =~ "unknown channel for goodbye send"
    refute_enqueued(worker: TelegramOutboundWorker)
  end

  # ----------------------------------------------------------------
  # PR-1 (#86) — channel-neutral dispatch.
  # Telegram channel enqueues a TelegramOutboundWorker goodbye job
  # (patient_id: nil — goodbyes are nil-safe per design).
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

      # Issue #198 — the :emotion_analyzer slot is wired to
      # Alethea.AI.EmotionAnalyzer.Fake (deterministic joy=0.8 dominant).
      # No explicit mock expectation needed.

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

      # Close-flow side effects (primary-path coverage): the session is
      # closed and its trends + summary are persisted.
      assert Repo.get!(Session, session.id).status == "closed"
      assert length(Repo.all(from(t in Trend, where: t.patient_id == ^patient.id))) == 5
      assert length(Repo.all(from(s in Summary, where: s.patient_id == ^patient.id))) == 1
    end

    test "telegram-channel idempotent skip: closed session short-circuits, NO TelegramOutboundWorker enqueued",
         %{session: session, patient: patient, telegram_args: targs} do
      {:ok, _} = SessionManager.close_session(session)

      targs = %{targs | session_id: session.id, patient_id: patient.id}

      # Issue #198 — the :emotion_analyzer slot is wired to
      # Alethea.AI.EmotionAnalyzer.Fake (deterministic). The Fake would
      # return its fixed vector if invoked, but the close-skip guard
      # must short-circuit BEFORE the analyzer runs — we assert that
      # indirectly by checking NO trends or summary are persisted.
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, 0, fn _, _ ->
        flunk("SessionSummaryChain must not run on closed session")
      end)

      assert :ok = perform_job(SessionTimeoutWorker, targs)

      refute_enqueued(worker: TelegramOutboundWorker)
      assert Repo.aggregate(Trend, :count) == 0
      assert Repo.aggregate(Summary, :count) == 0
    end
  end

  # ----------------------------------------------------------------
  # Issue #334 — a surprise/disgust-dominant emotion result must not
  # halt the close flow. `Alethea.AI.EmotionAnalyzer.Fake` (the default
  # test-env slot) always returns a fixed joy-dominant vector, so it
  # cannot exercise this path. Instead, this describe block swaps the
  # :emotion_analyzer slot to the REAL `Alethea.AI.EmotionAnalyzer` and
  # stubs its HTTP sidecar call with `Req.Test` (the same technique
  # `emotion_analyzer_test.exs` uses) so the fix is proven through the
  # real parsing/projection code, not a hand-rolled score list.
  # ----------------------------------------------------------------

  describe "surprise/disgust dominant emotion (issue #334)" do
    setup do
      previous_analyzer = Application.get_env(:alethea, :emotion_analyzer)
      previous_config = Application.get_env(:alethea, EmotionAnalyzer)

      Application.put_env(:alethea, :emotion_analyzer, EmotionAnalyzer)

      Application.put_env(:alethea, EmotionAnalyzer,
        base_url: "http://emotion-sidecar.test",
        connect_timeout: 100,
        receive_timeout: 100,
        max_batch_size: 32,
        max_text_bytes: 4096,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

      on_exit(fn ->
        Application.put_env(:alethea, :emotion_analyzer, previous_analyzer)
        Application.put_env(:alethea, EmotionAnalyzer, previous_config)
      end)

      :ok
    end

    defp stub_sidecar_result(dominant, overrides) do
      official_labels = ~w(others joy sadness anger surprise disgust fear)
      scores = Map.merge(Map.new(official_labels, &{&1, 0.0}), overrides)

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "version" => "v1",
          "results" => [%{"label" => dominant, "scores" => scores}]
        })
      end)
    end

    test "surprise-dominant message: close flow completes (trends saved, summary saved, goodbye sent)",
         %{session: session, patient: patient} do
      stub_sidecar_result("surprise", %{
        "surprise" => 0.6,
        "joy" => 0.1,
        "sadness" => 0.1,
        "anger" => 0.05,
        "fear" => 0.05,
        "others" => 0.1
      })

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        {:ok, "1. Estado: alegre\n2. Temas: trabajo\n3. Cambios: mejora\n4. Estable"}
      end)

      assert :ok =
               perform_job(SessionTimeoutWorker, %{
                 session_id: session.id,
                 patient_id: patient.id,
                 channel: "telegram",
                 chat_id: 987_654_321,
                 chat_id_hash: "test_chat_id_hash_abcdef"
               })

      assert Repo.get!(Session, session.id).status == "closed"
      assert length(Repo.all(from(t in Trend, where: t.patient_id == ^patient.id))) == 5
      assert length(Repo.all(from(s in Summary, where: s.patient_id == ^patient.id))) == 1
      assert_enqueued(worker: TelegramOutboundWorker)
    end

    test "disgust-dominant message: close flow completes (trends saved, summary saved, goodbye sent)",
         %{session: session, patient: patient} do
      stub_sidecar_result("disgust", %{
        "disgust" => 0.7,
        "joy" => 0.05,
        "sadness" => 0.1,
        "anger" => 0.05,
        "fear" => 0.05,
        "others" => 0.05
      })

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        {:ok, "1. Estado: alegre\n2. Temas: trabajo\n3. Cambios: mejora\n4. Estable"}
      end)

      assert :ok =
               perform_job(SessionTimeoutWorker, %{
                 session_id: session.id,
                 patient_id: patient.id,
                 channel: "telegram",
                 chat_id: 987_654_321,
                 chat_id_hash: "test_chat_id_hash_abcdef"
               })

      assert Repo.get!(Session, session.id).status == "closed"
      assert length(Repo.all(from(t in Trend, where: t.patient_id == ^patient.id))) == 5
      assert length(Repo.all(from(s in Summary, where: s.patient_id == ^patient.id))) == 1
      assert_enqueued(worker: TelegramOutboundWorker)
    end
  end

  # ----------------------------------------------------------------
  # Issue #402 — AI capability degradation.
  #
  # Emotion trends are an optional step of the closure. The session
  # summary and the goodbye do not depend on them, so a disabled or
  # failing analyzer must not leave the closure half-done, and nothing
  # may be recorded from a capability that produced no valid result.
  # ----------------------------------------------------------------

  describe "AI capability degradation (issue #402)" do
    @summary_text "1. Estado: alegre\n2. Temas: trabajo\n3. Cambios: mejora\n4. Estable"
    @message_text "Me siento bien hoy"

    defp telegram_job_args(session, patient) do
      %{
        session_id: session.id,
        patient_id: patient.id,
        channel: "telegram",
        chat_id: 987_654_321,
        chat_id_hash: "test_chat_id_hash_abcdef"
      }
    end

    defp goodbye_jobs do
      Repo.all(from j in Oban.Job, where: j.worker == "Alethea.Jobs.TelegramOutboundWorker")
    end

    defp session_summaries(patient) do
      Repo.all(from(s in Summary, where: s.patient_id == ^patient.id))
    end

    test "a disabled analyzer is not an error: summary and goodbye complete, no trends recorded",
         %{patient: patient, session: session} do
      Application.put_env(:alethea, :emotion_analyzer, EmotionAnalyzer.Disabled)

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn texts, scores ->
        # No emotion profile is fabricated for the summary prompt.
        assert texts == [@message_text]
        assert scores == []
        {:ok, @summary_text}
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))
        end)

      assert Repo.get!(Session, session.id).status == "closed"
      assert Repo.aggregate(Trend, :count) == 0
      assert Repo.aggregate(Alethea.Clinical.EmotionAnalysis, :count) == 0
      assert [%Summary{summary_text: @summary_text}] = session_summaries(patient)
      assert [_goodbye] = goodbye_jobs()

      # A switched-off capability is not reported as a failure.
      refute log =~ "[error]"
      refute log =~ "[warning]"
    end

    test "an unavailable analyzer records no trends and the closure still completes",
         %{patient: patient, session: session} do
      Application.put_env(:alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzerBehaviourMock)

      Alethea.AI.EmotionAnalyzerBehaviourMock
      |> expect(:analyze_batch, fn _texts -> {:error, :unavailable} end)

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, scores ->
        assert scores == []
        {:ok, @summary_text}
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))
        end)

      assert Repo.aggregate(Trend, :count) == 0
      assert [%Summary{}] = session_summaries(patient)
      assert [_goodbye] = goodbye_jobs()

      # The skipped step is observable: capability and reason tag only.
      assert log =~ "capability=emotion_analyzer"
      assert log =~ "reason=:unavailable"
      refute log =~ @message_text
      refute log =~ "987654321"
      refute log =~ "test_chat_id_hash_abcdef"
    end

    test "malformed analyzer scores record no trends and the closure still completes",
         %{patient: patient, session: session} do
      Application.put_env(:alethea, :emotion_analyzer, Alethea.AI.EmotionAnalyzerBehaviourMock)

      Alethea.AI.EmotionAnalyzerBehaviourMock
      |> expect(:analyze_batch, fn _texts -> {:ok, [%{label: "joy", score: 0.8}]} end)

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, scores ->
        # The rejected vector never reaches the summary prompt.
        assert scores == []
        {:ok, @summary_text}
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))
        end)

      assert Repo.aggregate(Trend, :count) == 0
      assert [%Summary{}] = session_summaries(patient)
      assert [_goodbye] = goodbye_jobs()
      assert log =~ "reason=:invalid_emotion_scores"
    end

    test "an unavailable summary chain still sends the goodbye and records no summary",
         %{patient: patient, session: session} do
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        {:error, "LLM endpoint for the :local provider is not configured"}
      end)

      capture_log(fn ->
        # The failure is surfaced so Oban retries the missing summary.
        assert {:error, _reason} =
                 perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))
      end)

      assert Repo.get!(Session, session.id).status == "closed"
      assert session_summaries(patient) == []
      assert [goodbye] = goodbye_jobs()
      assert goodbye.args["body"] =~ "Tu sesión de hoy ha concluido"
      # Trends come from the analyzer, which did succeed.
      assert Repo.aggregate(Trend, :count) == 5
    end

    test "a retry completes the missing summary without a second goodbye or duplicate trends",
         %{patient: patient, session: session} do
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores -> {:error, :timeout} end)
      |> expect(:run, fn _texts, scores ->
        # Trends cannot be attributed to a session, so a retry never
        # re-runs the analyzer and never repeats them.
        assert scores == []
        {:ok, @summary_text}
      end)

      args = telegram_job_args(session, patient)

      capture_log(fn ->
        assert {:error, :timeout} = perform_job(SessionTimeoutWorker, args, attempt: 1)
      end)

      assert :ok = perform_job(SessionTimeoutWorker, args, attempt: 2)

      assert [%Summary{summary_text: @summary_text}] = session_summaries(patient)
      assert [_single_goodbye] = goodbye_jobs()
      assert Repo.aggregate(Trend, :count) == 5
    end

    test "a retry of a finished closure repeats nothing",
         %{patient: patient, session: session} do
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, 1, fn _texts, _scores -> {:ok, @summary_text} end)

      args = telegram_job_args(session, patient)

      assert :ok = perform_job(SessionTimeoutWorker, args, attempt: 1)
      assert :ok = perform_job(SessionTimeoutWorker, args, attempt: 2)
      assert :ok = perform_job(SessionTimeoutWorker, args, attempt: 3)

      assert [_single_summary] = session_summaries(patient)
      assert [_single_goodbye] = goodbye_jobs()
      assert Repo.aggregate(Trend, :count) == 5
    end

    test "the goodbye of one session does not suppress the goodbye of the next",
         %{patient: patient, session: session} do
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, 2, fn _texts, _scores -> {:ok, @summary_text} end)

      assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))

      # A session summary is matched by the session's own period, which
      # has one-second precision. Real sessions last at least the
      # inactivity window, so two sessions of a patient never share a
      # period; the test spaces them explicitly instead of sleeping.
      {:ok, next_session} = SessionManager.open_session(patient)

      next_session =
        next_session
        |> Ecto.Changeset.change(started_at: DateTime.add(next_session.started_at, -3600))
        |> Repo.update!()

      assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(next_session, patient))

      assert length(goodbye_jobs()) == 2
      assert length(session_summaries(patient)) == 2
    end

    test "accepts the summary shape returned by the real summary chain",
         %{patient: patient, session: session} do
      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores ->
        {:ok, %{summary: "1. Estado\n2. Temas\n3. Cambios\n4. Alerta", tokens_used: 12}}
      end)

      assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))

      assert [%Summary{summary_text: "1. Estado\n2. Temas\n3. Cambios\n4. Alerta"} = summary] =
               session_summaries(patient)

      assert summary.status_level == "Alerta"
    end

    test "degraded closure leaves behaviour tags and message anchoring untouched",
         %{patient: patient, session: session} do
      Application.put_env(:alethea, :emotion_analyzer, EmotionAnalyzer.Disabled)

      before =
        Repo.all(
          from m in Alethea.Clinical.Message,
            where: m.patient_id == ^patient.id,
            select: {m.id, m.behavior_type, m.direction, m.session_id}
        )

      Alethea.AI.SessionSummaryChainMock
      |> expect(:run, fn _texts, _scores -> {:ok, @summary_text} end)

      assert :ok = perform_job(SessionTimeoutWorker, telegram_job_args(session, patient))

      assert [{_id, "spontaneous", "inbound", session_id}] = before
      assert session_id == session.id

      assert before ==
               Repo.all(
                 from m in Alethea.Clinical.Message,
                   where: m.patient_id == ^patient.id,
                   select: {m.id, m.behavior_type, m.direction, m.session_id}
               )
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
      # Issue #198 — the :emotion_analyzer slot is wired to
      # Alethea.AI.EmotionAnalyzer.Fake (deterministic joy=0.8 dominant).
      # No explicit mock expectation needed; the Fake provides the
      # score vector that feeds the SessionSummaryChain.

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
      # Issue #198 — the :emotion_analyzer slot is wired to
      # Alethea.AI.EmotionAnalyzer.Fake (deterministic joy=0.8 dominant).
      # No explicit mock expectation needed; the Fake provides the
      # score vector that feeds the SessionSummaryChain.

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
