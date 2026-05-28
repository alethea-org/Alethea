defmodule AletheaJobs.SessionTimeoutWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query

  alias Alethea.{Accounts, Repo}
  alias Alethea.Clinical.{Session, SessionManager, Summary, Trend}
  alias AletheaJobs.SessionTimeoutWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "timeout_test@example.com",
        password: "securepassword123",
        full_name: "Timeout Tester"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    # Crear paciente usando la lógica real para que tenga llaves y cifrado correcto
    {:ok, patient} =
      Accounts.create_patient(
        %{
          "whatsapp_number" => "+541100000000",
          "alias" => "Test Patient",
          "professional_id" => professional.id
        },
        kek
      )

    {:ok, _} = Accounts.update_patient_terms(patient, true)
    patient = Accounts.get_patient!(patient.id)

    {:ok, session} = SessionManager.open_session(patient)

    # Guardar mensaje usando Clinical.save_message para usar el cifrado correcto
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

    %{patient: patient, session: session}
  end

  test "creates Trend records and a session Summary after closing", %{
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
               phone: "+541100000000"
             })

    trends = Repo.all(from t in Trend, where: t.patient_id == ^patient.id)
    assert length(trends) == 5

    summaries = Repo.all(from s in Summary, where: s.patient_id == ^patient.id)
    assert length(summaries) == 1
    assert hd(summaries).type == "session"

    closed_session = Repo.get!(Session, session.id)
    assert closed_session.status == "closed"
  end

  test "is idempotent when session is already closed", %{session: session, patient: patient} do
    {:ok, _} = SessionManager.close_session(session)

    assert :ok =
             perform_job(SessionTimeoutWorker, %{
               session_id: session.id,
               patient_id: patient.id,
               phone: "+541100000000"
             })

    assert Repo.all(from t in Trend, where: t.patient_id == ^patient.id) == []
  end
end
