defmodule AletheaJobs.SessionTimeoutWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query

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

  test "creates Trend records and a session Summary after closing", %{
    patient: patient,
    session: session,
    phone: phone
  } do
    emotion_scores = [
      %{label: "joy", score: 0.80},
      %{label: "sadness", score: 0.05},
      %{label: "anger", score: 0.05},
      %{label: "fear", score: 0.05},
      %{label: "neutral", score: 0.05}
    ]

    # Setup expectations - the mock is already configured via test.exs config
    Alethea.AI.RoBERTaWorkerMock
    |> expect(:analyze_batch, fn _texts -> emotion_scores end)

    Alethea.AI.SessionSummaryChainMock
    |> expect(:run, fn _texts, _scores ->
      {:ok, "1. Estado: alegre\n2. Temas: trabajo\n3. Cambios: mejora\n4. Estable"}
    end)

    Alethea.WhatsApp.ClientMock
    |> expect(:send_message, fn _phone, body ->
      assert body =~ "Tu sesión de hoy ha concluido"
      {:ok, %{}}
    end)

    assert :ok =
             perform_job(SessionTimeoutWorker, %{
               session_id: session.id,
               patient_id: patient.id,
               phone: phone
             })

    trends = Repo.all(from(t in Trend, where: t.patient_id == ^patient.id))
    assert length(trends) == 5

    summaries = Repo.all(from(s in Summary, where: s.patient_id == ^patient.id))
    assert length(summaries) == 1
    assert hd(summaries).type == "session"

    closed_session = Repo.get!(Session, session.id)
    assert closed_session.status == "closed"
  end

  test "is idempotent when session is already closed", %{
    session: session,
    patient: patient,
    phone: phone
  } do
    {:ok, _} = SessionManager.close_session(session)

    assert :ok =
             perform_job(SessionTimeoutWorker, %{
               session_id: session.id,
               patient_id: patient.id,
               phone: phone
             })

    assert Repo.all(from(t in Trend, where: t.patient_id == ^patient.id)) == []
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

    test "telegram-channel args enqueue TelegramOutboundWorker goodbye (chat_id, chat_id_hash, body, patient_id: nil) and do NOT call whatsapp_client",
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

      # WhatsApp client MUST NOT be called on the telegram channel —
      # `verify_on_exit!` would catch an unexpected call. Set an
      # explicit 0-call expectation so the assertion is unambiguous
      # (Mox fails the test if `send_message/2` lands even once).
      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, 0, fn _phone, _body ->
        flunk("whatsapp_client must NOT be invoked on the telegram channel")
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

      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, 0, fn _, _ ->
        flunk("whatsapp_client must not run on closed session")
      end)

      assert :ok = perform_job(SessionTimeoutWorker, targs)

      refute_enqueued(worker: TelegramOutboundWorker)
    end
  end
end
