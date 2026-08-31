defmodule AletheaWeb.TargetBehaviorLive.ReviewTest do
  @moduledoc """
  `Phoenix.LiveViewTest` specs for `AletheaWeb.TargetBehaviorLive.Review`
  (PR3, sdd/alethea/issue-195-clinical-review-workbench, GitHub #195).

  Mirrors the spec's UI-facing acceptance scenarios: chronological merge
  across all 3 kinds, immutable-excerpt + source display, uncited
  clinician-observation marking, provisional-only AI proposals with
  explicit per-item accept/edit/discard (no default confirm), the
  editable functional-analysis draft, and an explicit-and-separate
  clinical-note-creation action.
  """
  use AletheaWeb.ConnCase
  use Oban.Testing, repo: Alethea.Repo
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence
  }

  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  @password "supersecret12"

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    target_behavior = create_target_behavior!(professional, patient)

    %{patient: patient, target_behavior: target_behavior}
  end

  describe "mount — authorized chronological review access" do
    test "merges evidence, observation, and proposal in ascending occurred_at order", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)
      t1 = ~U[2026-01-01 10:00:00.000000Z]
      t2 = ~U[2026-01-01 11:00:00.000000Z]
      t3 = ~U[2026-01-01 12:00:00.000000Z]

      insert_evidence!(
        professional,
        patient,
        target_behavior,
        dek,
        t1,
        "clinical_note",
        Ecto.UUID.generate(),
        "Cita textual del profesional"
      )

      insert_observation!(professional, patient, target_behavior, dek, t2, "Observacion directa")
      insert_proposal!(professional, patient, target_behavior, dek, t3, "Patron sugerido")

      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Cita textual del profesional"
      assert html =~ "Observacion directa"
      assert html =~ "Patron sugerido"

      # Ascending occurred_at order — evidence, then observation, then proposal.
      evidence_pos = :binary.match(html, "Cita textual del profesional") |> elem(0)
      observation_pos = :binary.match(html, "Observacion directa") |> elem(0)
      proposal_pos = :binary.match(html, "Patron sugerido") |> elem(0)

      assert evidence_pos < observation_pos
      assert observation_pos < proposal_pos

      assert has_element?(view, "form#draft-form")
    end
  end

  describe "mount — non-responsible professional is denied" do
    test "redirects to /patients with a flash and fetches no timeline data", %{
      patient: patient,
      target_behavior: target_behavior
    } do
      other_professional = create_professional!()
      other_conn = log_in_professional(build_conn(), other_professional)

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(
                 other_conn,
                 ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review"
               )
    end
  end

  describe "immutable evidence excerpt + source reference display" do
    test "renders the byte-identical excerpt alongside its resolved source reference", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, "Nota citada")

      insert_evidence!(
        professional,
        patient,
        target_behavior,
        dek,
        DateTime.utc_now(),
        "clinical_note",
        note.id,
        "Excerpt exacto capturado al citar"
      )

      {:ok, _view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Excerpt exacto capturado al citar"
      assert html =~ "Nota clínica"
      assert html =~ "Evidencia citada"
    end

    test "a deleted source still renders the excerpt with an unavailable source reference", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      insert_evidence!(
        professional,
        patient,
        target_behavior,
        dek,
        DateTime.utc_now(),
        "clinical_note",
        Ecto.UUID.generate(),
        "Excerpt que sobrevive al origen"
      )

      {:ok, _view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Excerpt que sobrevive al origen"
      assert html =~ "Fuente no disponible"
    end
  end

  describe "uncited clinician observation marking" do
    test "an observation renders labeled uncited with no source citation", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      insert_observation!(
        professional,
        patient,
        target_behavior,
        dek,
        DateTime.utc_now(),
        "Observacion sin cita"
      )

      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Observacion sin cita"
      assert has_element?(view, ".review-item--observation .badge--uncited")
    end

    test "adding an observation via the form persists it uncited on the timeline", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> form("#observation-form", observation: %{body: "Nueva observacion del clinico"})
        |> render_submit()

      assert html =~ "Nueva observacion del clinico"
      assert Repo.aggregate(ClinicianObservation, :count) == 1
    end
  end

  describe "provisional-only AI proposal presentation" do
    test "shows zero AI proposals before suggest_patterns has ever been triggered", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, ".review-item--proposal")
    end

    test "suggest_patterns enqueues the AI worker by name and disables the trigger", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> element("#suggest-patterns")
        |> render_click()

      assert_enqueued(worker: "AletheaJobs.AIProposalWorker")
      assert has_element?(view, "#suggest-patterns[disabled]")
      assert html =~ "Generando"
    end

    test "a pending proposal renders provisional and never as note typography", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      insert_proposal!(
        professional,
        patient,
        target_behavior,
        dek,
        DateTime.utc_now(),
        "Patron pendiente"
      )

      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Patron pendiente"
      assert has_element?(view, ".review-item--proposal .badge--provisional")
      refute has_element?(view, ".review-item--proposal .review-item--note")
    end
  end

  describe "explicit per-proposal accept/edit/discard — no default confirm" do
    test "a pending proposal exposes explicit accept/edit/discard controls, none pre-selected",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      proposal =
        insert_proposal!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "Patron a decidir"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(
               view,
               "button[phx-click='accept_proposal'][phx-value-id='#{proposal.id}']"
             )

      assert has_element?(
               view,
               "button[phx-click='discard_proposal'][phx-value-id='#{proposal.id}']"
             )

      assert has_element?(
               view,
               "button[phx-click='start_edit_proposal'][phx-value-id='#{proposal.id}']"
             )

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "pending"
    end

    test "accepting a proposal updates its status and merges its text into the draft", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      proposal =
        insert_proposal!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "Patron a aceptar"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> element("button[phx-click='accept_proposal'][phx-value-id='#{proposal.id}']")
      |> render_click()

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "accepted"

      assert {:ok, %{body: body}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert body =~ "Patron a aceptar"

      assert Repo.aggregate(ClinicalNote, :count) == 0
    end

    test "editing a proposal preserves the original AI text and marks status edited", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      proposal =
        insert_proposal!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "Texto original de la IA"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> element("button[phx-click='start_edit_proposal'][phx-value-id='#{proposal.id}']")
      |> render_click()

      assert has_element?(view, "form#edit-proposal-#{proposal.id}")

      html =
        view
        |> form("#edit-proposal-#{proposal.id}",
          proposal: %{text: "Texto editado por el clinico"}
        )
        |> render_submit()

      assert html =~ "Texto editado por el clinico"

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "edited"
      assert reloaded.encrypted_original_text == proposal.encrypted_original_text
      refute reloaded.encrypted_text == proposal.encrypted_text
    end

    test "discarding a proposal marks it discarded but keeps it visible on the timeline", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      proposal =
        insert_proposal!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "Patron a descartar"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> element("button[phx-click='discard_proposal'][phx-value-id='#{proposal.id}']")
        |> render_click()

      assert html =~ "Patron a descartar"
      assert has_element?(view, ".badge--status-discarded")

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "discarded"
      assert Repo.aggregate(AIProposal, :count) == 1
    end
  end

  describe "editable functional-analysis draft and explicit note creation" do
    test "saving the draft persists it without creating a clinical note", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#draft-form", draft: %{body: "Analisis funcional editado a mano"})
      |> render_submit()

      assert Repo.aggregate(ClinicalNote, :count) == 0
    end

    test "note creation is a distinct explicit action separate from accept/draft-save", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> form("#note-form", note: %{body: "Nota clinica final"})
        |> render_submit()

      assert html =~ "Nota clínica creada"
      assert Repo.aggregate(ClinicalNote, :count) == 1
    end
  end

  describe "web layer boundary — no Repo/PatientVault access in the LiveView" do
    test "the LiveView source never references Repo or PatientVault directly" do
      source =
        File.read!(
          Path.join([
            File.cwd!(),
            "lib",
            "alethea_web",
            "live",
            "target_behavior_live",
            "review.ex"
          ])
        )

      refute source =~ ~r/alias\s+Alethea\.Repo/
      refute source =~ ~r/\bRepo\./
      refute source =~ ~r/PatientVault\./
      refute source =~ ~r/load_professional_kek\(/
      refute source =~ ~r/load_patient_dek\(/
    end
  end

  defp load_dek!(professional, patient) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    dek
  end

  defp insert_evidence!(
         professional,
         patient,
         target_behavior,
         dek,
         occurred_at,
         source_kind,
         source_id,
         excerpt
       ) do
    {:ok, ciphertext} = PatientVault.encrypt(excerpt, dek)

    %ConsultationEvidence{}
    |> ConsultationEvidence.changeset(%{
      source_kind: source_kind,
      source_id: source_id,
      encrypted_excerpt: ciphertext,
      occurred_at: occurred_at,
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id
    })
    |> Repo.insert!()
  end

  defp insert_observation!(professional, patient, target_behavior, dek, occurred_at, body) do
    {:ok, ciphertext} = PatientVault.encrypt(body, dek)

    %ClinicianObservation{}
    |> ClinicianObservation.changeset(%{
      encrypted_body: ciphertext,
      occurred_at: occurred_at,
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id
    })
    |> Repo.insert!()
  end

  defp insert_proposal!(professional, patient, target_behavior, dek, occurred_at, text) do
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    %AIProposal{}
    |> AIProposal.changeset(%{
      encrypted_original_text: ciphertext,
      encrypted_text: ciphertext,
      model_version: "phi4-mini-test",
      occurred_at: occurred_at,
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id
    })
    |> Repo.insert!()
  end

  defp create_target_behavior!(professional, patient) do
    {:ok, target_behavior} =
      ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta objetivo")

    target_behavior
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "review-live-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Review Live"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
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
