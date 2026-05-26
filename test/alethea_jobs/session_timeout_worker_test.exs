defmodule AletheaJobs.SessionTimeoutWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query

  alias Alethea.{Accounts, Repo}
  alias Alethea.Clinical.{Session, SessionManager, Summary, Trend}
  alias AletheaJobs.SessionTimeoutWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, professional} =
      Accounts.create_professional(%{
        email: "timeout_test@example.com",
        password: "securepassword123",
        full_name: "Timeout Tester"
      })

    patient =
      Repo.insert!(%Alethea.Accounts.Patient{
        alias: "Test Patient",
        professional_id: professional.id,
        whatsapp_number_hash: Ecto.UUID.generate(),
        encrypted_whatsapp_number: Alethea.Encryption.Vault.encrypt!("+541100000000"),
        terms_accepted: true,
        status: "active"
      })

    {:ok, session} = SessionManager.open_session(patient)

    encrypted = Alethea.Encryption.Vault.encrypt!("Me siento bien hoy")

    Repo.insert!(%Alethea.Clinical.Message{
      direction: "inbound",
      encrypted_content: encrypted,
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      patient_id: patient.id,
      session_id: session.id
    })

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
    |> expect(:run, fn _texts, _scores -> {:ok, "Estado: alegre\nTemas: trabajo\nCambios: mejora\nEstable"} end)

    Alethea.WhatsApp.ClientMock
    |> expect(:send_message, fn _phone, _msg -> :ok end)

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
