defmodule AletheaWeb.ClinicalNoteLiveTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.ClinicalNote
  alias Alethea.Encryption.PatientVault
  alias AletheaJobs.ClinicalRecordOutboxWorker

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    %{patient: patient}
  end

  describe "authorization" do
    test "redirects a non-treating professional", %{patient: patient} do
      other_professional = create_professional!()
      other_conn = log_in_professional(build_conn(), other_professional)

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(other_conn, ~p"/patients/#{patient.id}/clinical-notes")
    end
  end

  describe "navigation from dashboard" do
    test "dashboard renders clinical notes links for the selected patient", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#patient-clinical-notes-link")
      assert has_element?(view, "#patient-clinical-notes-action")

      {:ok, notes_view, _html} =
        view
        |> element("#patient-clinical-notes-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/patients/#{patient.id}/clinical-notes")

      assert has_element?(notes_view, "#clinical-note-form")
    end
  end

  describe "clinical notes view" do
    test "displays empty state and immutability notice when patient has no notes", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      assert has_element?(view, "#clinical-notes-empty")
      assert has_element?(view, "#immutability-notice")
      assert has_element?(view, "#clinical-note-form")
      assert has_element?(view, "#save-clinical-note-button")
    end

    test "validates that note content cannot be empty", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      html =
        view
        |> form("#clinical-note-form", %{"clinical_note" => %{"body" => "   "}})
        |> render_submit()

      assert html =~ "El contenido de la nota clínica no puede estar vacío."
      assert has_element?(view, "#clinical-notes-empty")
    end

    test "creates an immutable clinical note and renders it with author and date", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      note_body = "Sesión 1: El paciente manifiesta buena disposición al tratamiento."

      html =
        view
        |> form("#clinical-note-form", %{"clinical_note" => %{"body" => note_body}})
        |> render_submit()

      assert html =~ "Nota clínica creada exitosamente."
      refute has_element?(view, "#clinical-notes-empty")
      assert has_element?(view, "#clinical-notes-list")
      assert html =~ note_body
      assert html =~ professional.full_name

      assert_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "lists existing notes in reverse chronological order", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, ciphertext} = PatientVault.encrypt("Nota antigua", dek)

      past_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      _older_note =
        %ClinicalNote{inserted_at: past_time}
        |> ClinicalNote.changeset(%{
          patient_id: patient.id,
          professional_id: professional.id,
          encrypted_body: ciphertext
        })
        |> Alethea.Repo.insert!()

      assert {:ok, _newer_note} =
               ClinicalRecord.create_clinical_note(professional, patient.id, "Nota más reciente")

      {:ok, _view, html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      newer_index = :binary.match(html, "Nota más reciente") |> elem(0)
      older_index = :binary.match(html, "Nota antigua") |> elem(0)

      assert newer_index < older_index
    end
  end

  describe "risk toggle" do
    defp submit_note(view, body, risk_change) do
      view
      |> form("#clinical-note-form", %{
        "clinical_note" => %{"body" => body, "risk_change" => risk_change}
      })
      |> render_submit()
    end

    test "form offers no change (default), activate and deactivate risk", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      assert has_element?(view, "#risk-change-none[checked]")
      assert has_element?(view, "#risk-change-activated")
      assert has_element?(view, "#risk-change-deactivated")
      assert has_element?(view, "#patient-risk-status", "Sin riesgo activo")
    end

    test "activating risk saves the note, flags the patient and marks the note", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      html = submit_note(view, "Ideación activa en sesión", "activated")

      assert html =~ "Nota clínica creada exitosamente."
      assert has_element?(view, "#clinical-notes-list .risk-change-badge", "Riesgo activado")
      assert has_element?(view, "#patient-risk-status", "Riesgo activo")
      assert has_element?(view, "#risk-change-none[checked]")
      assert Accounts.get_patient!(patient.id).urgent_intervention
    end

    test "deactivating risk clears the patient's urgent intervention", %{
      conn: conn,
      patient: patient
    } do
      {:ok, _} = Accounts.update_patient(patient, %{urgent_intervention: true})
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      assert has_element?(view, "#patient-risk-status", "Riesgo activo")

      submit_note(view, "Riesgo contenido", "deactivated")

      assert has_element?(view, "#clinical-notes-list .risk-change-badge", "Riesgo desactivado")
      assert has_element?(view, "#patient-risk-status", "Sin riesgo activo")
      refute Accounts.get_patient!(patient.id).urgent_intervention
    end

    test "deactivating without an active risk shows an error and saves nothing", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      html = submit_note(view, "Nota", "deactivated")

      assert html =~ "El paciente no tiene un riesgo activo."
      assert has_element?(view, "#clinical-notes-empty")
    end

    test "activating an already active risk shows an error and saves nothing", %{
      conn: conn,
      patient: patient
    } do
      {:ok, _} = Accounts.update_patient(patient, %{urgent_intervention: true})
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      html = submit_note(view, "Nota", "activated")

      assert html =~ "El paciente ya tiene un riesgo activo."
      assert has_element?(view, "#clinical-notes-empty")
    end

    test "existing notes show their risk change", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      {:ok, _} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Alta de riesgo",
          risk_change: :activated
        )

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-notes")

      assert has_element?(view, "#clinical-notes-list .risk-change-badge", "Riesgo activado")
    end
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    professional = create_professional!()
    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
