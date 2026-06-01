defmodule Alethea.Clinical.SessionManagerTest do
  use Alethea.DataCase, async: false

  alias Alethea.Clinical.SessionManager

  setup do
    # Create professional and load KEK
    {:ok, professional} =
      Alethea.Accounts.create_professional(%{
        email: "test-#{System.unique_integer()}@test.com",
        password: "password12345",
        full_name: "Dr. Test"
      })

    {:ok, kek_bytes} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{
          "whatsapp_number" => "+5491111111111",
          "alias" => "test-patient",
          "professional_id" => professional.id
        },
        kek_bytes
      )

    %{patient: patient, professional: professional}
  end

  describe "current_open_session/1" do
    test "creates a new session when none exists", %{patient: patient} do
      assert {:ok, session} = SessionManager.current_open_session(patient.id)
      assert session.status == "open"
      assert session.patient_id == patient.id
      assert session.started_at != nil
    end

    test "returns existing open session", %{patient: patient} do
      {:ok, first_session} = SessionManager.current_open_session(patient.id)
      {:ok, second_session} = SessionManager.current_open_session(patient.id)

      assert first_session.id == second_session.id
    end

    test "returns open session, not closed one", %{patient: patient} do
      {:ok, session} = SessionManager.current_open_session(patient.id)
      SessionManager.close_session(session)

      {:ok, new_session} = SessionManager.current_open_session(patient.id)
      assert new_session.id != session.id
      assert new_session.status == "open"
    end
  end

  describe "open_session/1" do
    test "creates a new session with patient struct", %{patient: patient} do
      assert {:ok, session} = SessionManager.open_session(patient)
      assert session.patient_id == patient.id
      assert session.status == "open"
    end

    test "creates a new session with patient id map", %{patient: patient} do
      assert {:ok, session} = SessionManager.open_session(%{id: patient.id})
      assert session.patient_id == patient.id
      assert session.status == "open"
    end
  end

  describe "close_session/1" do
    test "closes an open session", %{patient: patient} do
      {:ok, session} = SessionManager.current_open_session(patient.id)

      assert {:ok, closed_session} = SessionManager.close_session(session)
      assert closed_session.status == "closed"
      assert closed_session.closed_at != nil
    end
  end
end
