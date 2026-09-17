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
