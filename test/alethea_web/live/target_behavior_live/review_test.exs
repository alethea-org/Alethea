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
  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    AIProposal,
    Audit,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    DismissedEvidenceSuggestion,
    FunctionalAnalysisContent,
    FunctionalAnalysisVersion,
    Retention,
    Tombstone
  }

  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias AletheaJobs.ClinicalRecordOutboxWorker

  @password "supersecret12"

  setup [:register_and_log_in_professional]
  setup :set_mox_from_context
  setup :verify_on_exit!

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

      assert has_element?(view, "#functional-analysis-form")

      # Non-transcript evidence never renders a speaker badge or time marker (R2/R3).
      refute has_element?(view, ".review-item--evidence .badge--speaker")
      refute has_element?(view, ".review-item--evidence .suggested-candidate-card__audio")
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

  describe "mount — cross-patient target behavior is denied (GitHub #289)" do
    test "redirects with a flash when the URL pairs patient A with patient B's target behavior",
         %{conn: conn, professional: professional, patient: patient_a} do
      patient_b = create_patient!(professional)
      target_b = create_target_behavior!(professional, patient_b)
      dek_b = load_dek!(professional, patient_b)

      insert_observation!(
        professional,
        patient_b,
        target_b,
        dek_b,
        ~U[2026-01-01 10:00:00.000000Z],
        "Observacion privada del paciente B"
      )

      assert {:error, {:live_redirect, %{to: "/patients", flash: flash}}} =
               live(conn, ~p"/patients/#{patient_a.id}/target_behaviors/#{target_b.id}/review")

      assert flash["error"] =~ "conducta objetivo"
      refute inspect(flash) =~ "Observacion privada del paciente B"
    end

    test "redirects with a flash when the target behavior id is malformed",
         %{conn: conn, patient: patient} do
      assert {:error, {:live_redirect, %{to: "/patients", flash: flash}}} =
               live(conn, ~p"/patients/#{patient.id}/target_behaviors/not-a-uuid/review")

      assert flash["error"] =~ "conducta objetivo"
    end
  end

  describe "target behavior gone after mount (GitHub #289)" do
    test "an AI generation failure because the target behavior was deleted redirects with a flash",
         %{conn: conn, patient: patient, target_behavior: target_behavior} do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      send(view.pid, {:ai_proposals_failed, :target_behavior_deleted})

      {path, flash} = assert_redirect(view)
      assert path == "/patients"
      assert flash["error"] =~ "conducta objetivo"
    end

    test "any other AI generation failure keeps the page and shows the generic flash",
         %{conn: conn, patient: patient, target_behavior: target_behavior} do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      send(view.pid, {:ai_proposals_failed, :timeout})

      assert render(view) =~ "La generación de patrones de IA falló."
      assert has_element?(view, "#functional-analysis-form")
    end

    test "a timeline refresh after the target behavior was deleted redirects instead of keeping stale items",
         %{
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
        "Observacion que ya no existe"
      )

      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Observacion que ya no existe"

      Repo.delete!(target_behavior)
      send(view.pid, {:ai_proposals_ready, target_behavior.id})

      {path, flash} = assert_redirect(view)
      assert path == "/patients"
      assert flash["error"] =~ "conducta objetivo"
    end

    test "a timeline refresh after losing authorization over the patient redirects with a flash",
         %{conn: conn, patient: patient, target_behavior: target_behavior} do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      Repo.delete!(patient)
      send(view.pid, {:ai_proposals_ready, target_behavior.id})

      {path, flash} = assert_redirect(view)
      assert path == "/patients"
      assert flash["error"] =~ "autorizado"
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

      view |> element("#toggle-observation-form") |> render_click()

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
        "Cita previa para habilitar sugerencias"
      )

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

    test "the proposals tab explains the provisional inbox and preserves proposal provenance", %{
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

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, "#proposal-inbox")
      view |> element("#input-tab-proposals") |> render_click()

      assert has_element?(view, "#proposal-inbox", "provisionales")
      assert has_element?(view, "#proposal-inbox", "E/O/R/C")
      assert has_element?(view, ".review-item--proposal", "Patron pendiente")
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

    test "accepting a proposal changes only its status and leaves structured draft content unchanged",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   "antecedents_distal" => "Cambio de rutina",
                   "response_motor" => "Evitó la tarea",
                   "previous_notes" => "Texto legado conservado\nSin clasificar"
                 }
               )

      assert {:ok, %{body: body_before}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

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

      assert render(view) =~
               "Propuesta aceptada. Permanece disponible para clasificación y ubicación manual."

      assert Repo.get!(AIProposal, proposal.id).status == "accepted"
      assert has_element?(view, ".badge--status-accepted")

      refute has_element?(
               view,
               "button[phx-click='accept_proposal'][phx-value-id='#{proposal.id}']"
             )

      assert has_element?(
               view,
               "#functional-analysis-antecedents-distal",
               "Cambio de rutina"
             )

      assert has_element?(view, "#functional-analysis-response-motor", "Evitó la tarea")
      assert has_element?(view, "#previous-notes", "Texto legado conservado")

      assert {:ok, %{body: ^body_before}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert Repo.aggregate(ClinicalNote, :count) == 0
    end

    test "accepting a proposal leaves a legacy free-text draft byte-identical", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)
      legacy_body = "Primera línea\n  Sangría intacta\nÚltima línea"

      assert {:ok, draft_before} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 legacy_body
               )

      proposal =
        insert_proposal!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "No incorporar automáticamente"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> element("button[phx-click='accept_proposal'][phx-value-id='#{proposal.id}']")
      |> render_click()

      assert Repo.get!(AIProposal, proposal.id).status == "accepted"

      draft_after = Repo.get!(draft_before.__struct__, draft_before.id)
      assert draft_after.encrypted_body == draft_before.encrypted_body
      assert draft_after.encryption_version == draft_before.encryption_version

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.previous_notes == legacy_body
      assert has_element?(view, "#previous-notes", "Primera línea")
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

  describe "responsive clinical workbench" do
    test "renders compact metadata, two stable panels, and tab controls with counts", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#clinical-workbench")
      assert has_element?(view, "#workbench-inputs-panel")
      assert has_element?(view, "#workbench-editor-panel")
      assert has_element?(view, "#review-stat-strip.review-metadata-strip")

      assert has_element?(
               view,
               "#input-tab-evidence[aria-selected='true'][aria-controls='review-timeline'][tabindex='0']",
               "Evidencia citada 0"
             )

      assert has_element?(
               view,
               "#input-tab-observations[aria-controls='review-timeline'][tabindex='-1']",
               "Observaciones 0"
             )

      assert has_element?(
               view,
               "#input-tab-proposals[aria-controls='review-timeline'][tabindex='-1']",
               "Propuestas IA 0"
             )

      assert has_element?(
               view,
               "#review-timeline.review-timeline--evidence[role='tabpanel'][aria-labelledby='input-tab-evidence']"
             )
    end

    test "ArrowLeft and ArrowRight move tab selection with wraparound", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> element("#input-tab-evidence")
      |> render_keydown(%{"key" => "ArrowRight"})

      assert has_element?(
               view,
               "#input-tab-observations[aria-selected='true'][tabindex='0']"
             )

      assert has_element?(
               view,
               "#review-timeline[aria-labelledby='input-tab-observations']"
             )

      view
      |> element("#input-tab-observations")
      |> render_keydown(%{"key" => "ArrowLeft"})

      assert has_element?(view, "#input-tab-evidence[aria-selected='true'][tabindex='0']")

      view
      |> element("#input-tab-evidence")
      |> render_keydown(%{"key" => "ArrowLeft"})

      assert has_element?(view, "#input-tab-proposals[aria-selected='true'][tabindex='0']")

      view
      |> element("#input-tab-proposals")
      |> render_keydown(%{"key" => "ArrowRight"})

      assert has_element?(view, "#input-tab-evidence[aria-selected='true'][tabindex='0']")
    end

    test "ArrowLeft and ArrowRight emit focus instructions for the newly selected tab", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> element("#input-tab-evidence")
      |> render_keydown(%{"key" => "ArrowRight"})

      assert_push_event(view, "focus_input_tab", %{id: "input-tab-observations"})

      view
      |> element("#input-tab-observations")
      |> render_keydown(%{"key" => "ArrowLeft"})

      assert_push_event(view, "focus_input_tab", %{id: "input-tab-evidence"})
    end

    test "switching tabs changes stream-safe parent state without removing timeline entries", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      observation =
        insert_observation!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "Observación conservada en el stream"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#input-tab-observations") |> render_click()

      assert has_element?(view, "#input-tab-observations[aria-selected='true']")
      assert has_element?(view, "#review-timeline.review-timeline--observations")

      assert has_element?(
               view,
               "#timeline-#{observation.id}",
               "Observación conservada en el stream"
             )
    end

    test "observation form starts collapsed and opens and cancels without persistence", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(
               view,
               "#toggle-observation-form[aria-controls='observation-entry'][aria-expanded='false']"
             )

      refute has_element?(view, "#observation-form")

      view |> element("#toggle-observation-form") |> render_click()

      assert has_element?(
               view,
               "#toggle-observation-form[aria-controls='observation-entry'][aria-expanded='true']"
             )

      assert has_element?(view, "#observation-form")

      view |> element("#toggle-observation-form") |> render_click()
      assert has_element?(view, "#toggle-observation-form[aria-expanded='false']")
      refute has_element?(view, "#observation-form")

      view |> element("#toggle-observation-form") |> render_click()
      view |> element("#cancel-observation") |> render_click()
      refute has_element?(view, "#observation-form")
      assert Repo.aggregate(ClinicianObservation, :count) == 0
    end
  end

  describe "structured E-O-R-C editor" do
    test "renders all eleven structured fields with stable IDs and blank missing values", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      for id <- [
            "antecedents-distal",
            "antecedents-immediate",
            "organism-sleep",
            "organism-pain-or-discomfort",
            "organism-hunger-or-nutrition",
            "organism-learning-history",
            "response-physiological",
            "response-cognitive",
            "response-motor",
            "consequences-short-term",
            "consequences-long-term"
          ] do
        assert has_element?(view, "#functional-analysis-#{id}[value='']") or
                 has_element?(view, "textarea#functional-analysis-#{id}")
      end
    end

    test "does not render previous notes when their value is empty", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, "#previous-notes")
      assert has_element?(view, "input[name='functional_analysis[previous_notes]'][value='']")
    end

    test "remounts a legacy free-text draft as visible read-only previous notes", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      legacy_body = "Primera línea completa\n  segunda línea con sangría\nÚltima línea"

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 legacy_body
               )

      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#previous-notes")
      assert has_element?(view, "#previous-notes .previous-notes__content")
      assert html =~ legacy_body
      assert html =~ "borrador anterior de texto libre"
      assert html =~ "no se clasificó automáticamente"

      assert has_element?(view, "input[name='functional_analysis[previous_notes]']")
    end

    test "remounts structured drafts with previous notes and preserves them byte-for-byte on save",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      previous_notes = "Legado estructurado\n  conservar espacios finales  \n"

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   "antecedents_immediate" => "Pedido inesperado",
                   "previous_notes" => previous_notes
                 }
               )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#previous-notes", "Legado estructurado")
      assert has_element?(view, "#functional-analysis-antecedents-immediate", "Pedido inesperado")

      view
      |> form("#functional-analysis-form",
        functional_analysis: %{
          antecedents_immediate: "Pedido actualizado",
          previous_notes: previous_notes
        }
      )
      |> render_submit()

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_immediate == "Pedido actualizado"
      assert content.previous_notes == previous_notes

      {:ok, remounted_view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(remounted_view, "#previous-notes", "Legado estructurado")
    end

    test "saves and restores E-O-R-C fields independently without creating a clinical note", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      params = %{
        antecedents_distal: "Cambio de rutina",
        antecedents_immediate: "Pedido inesperado",
        organism_sleep: "Sueño interrumpido",
        organism_pain_or_discomfort: "Sin dolor informado",
        organism_hunger_or_nutrition: "Omitió el desayuno",
        organism_learning_history: "Escalada aprendida",
        response_physiological: "Respiración acelerada",
        response_cognitive: "Anticipación de fracaso",
        response_motor: "Evitó la tarea",
        consequences_short_term: "Terminó la demanda",
        consequences_long_term: "Refuerzo de evitación"
      }

      html =
        view
        |> form("#functional-analysis-form", functional_analysis: params)
        |> render_submit()

      assert html =~ "Análisis funcional guardado."
      assert Repo.aggregate(ClinicalNote, :count) == 0

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_distal == "Cambio de rutina"
      assert content.organism_sleep == "Sueño interrumpido"
      assert content.response_motor == "Evitó la tarea"
      assert content.consequences_long_term == "Refuerzo de evitación"

      {:ok, restored_view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(
               restored_view,
               "#functional-analysis-antecedents-distal",
               "Cambio de rutina"
             )

      assert has_element?(
               restored_view,
               "#functional-analysis-consequences-long-term",
               "Refuerzo de evitación"
             )
    end
  end

  describe "AI-assisted E-O-R-C draft generation" do
    test "shows a prominent editor action and rejects generation without cited evidence", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(
               view,
               "#generate-functional-analysis-draft.button-primary[disabled]",
               "✨ Generar borrador E-O-R-C con IA"
             )

      render_click(view, "generate_functional_analysis_draft")

      assert render(view) =~ "No hay evidencia citada para generar el borrador."
      assert has_element?(view, "#functional-analysis-antecedents-distal", "")
    end

    test "sends only sanitized cited evidence, fills all blank fields, preserves edits, and saves only on request",
         %{
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
        "Contacto ana@example.com observó la conducta"
      )

      insert_observation!(
        professional,
        patient,
        target_behavior,
        dek,
        DateTime.utc_now(),
        "Observación clínica no citada"
      )

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   "antecedents_distal" => "Texto clínico guardado",
                   "previous_notes" => "Notas previas intactas"
                 }
               )

      test_pid = self()

      expect(Alethea.AI.FunctionalAnalysisDraftChainMock, :run, fn params ->
        send(test_pid, {:draft_chain_called, self(), params})
        receive do: (:finish_draft_generation -> generated_eorc_fields())
      end)

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#functional-analysis-form",
        functional_analysis: %{
          antecedents_distal: "Texto clínico guardado",
          response_motor: "Edición sin guardar",
          previous_notes: "Notas previas intactas"
        }
      )
      |> render_change()

      view |> element("#generate-functional-analysis-draft") |> render_click()

      assert_receive {:draft_chain_called, chain_pid,
                      %{sanitized_evidence: ["Contacto [REDACTED_EMAIL] observó la conducta"]}}

      view
      |> form("#functional-analysis-form",
        functional_analysis: %{
          antecedents_distal: "Texto clínico guardado",
          antecedents_immediate: "Edición realizada durante la solicitud",
          response_motor: "Edición sin guardar",
          previous_notes: "Notas previas intactas"
        }
      )
      |> render_change()

      send(chain_pid, :finish_draft_generation)
      render_async(view)

      assert render(view) =~ "Borrador E-O-R-C generado. Revisalo antes de guardar."

      assert has_element?(
               view,
               "#functional-analysis-antecedents-distal",
               "Texto clínico guardado"
             )

      assert has_element?(
               view,
               "#functional-analysis-antecedents-immediate",
               "Edición realizada durante la solicitud"
             )

      assert has_element?(view, "#functional-analysis-response-motor", "Edición sin guardar")
      assert has_element?(view, "#previous-notes", "Notas previas intactas")

      for field <-
            eorc_fields() -- ["antecedents_distal", "antecedents_immediate", "response_motor"] do
        assert has_element?(
                 view,
                 "#functional-analysis-#{String.replace(field, "_", "-")}",
                 "IA: #{field}"
               )
      end

      assert {:ok, saved_before} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert saved_before.antecedents_distal == "Texto clínico guardado"
      assert saved_before.organism_sleep == ""

      view |> form("#functional-analysis-form") |> render_submit()

      assert {:ok, saved_after} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert saved_after.antecedents_immediate == "Edición realizada durante la solicitud"
      assert saved_after.organism_sleep == "IA: organism_sleep"
      assert saved_after.response_motor == "Edición sin guardar"
      assert saved_after.previous_notes == "Notas previas intactas"
    end

    test "chain errors leave every unsaved editor value intact", %{
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
        "Evidencia citada"
      )

      expect(Alethea.AI.FunctionalAnalysisDraftChainMock, :run, fn _params ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#functional-analysis-form",
        functional_analysis: %{
          response_cognitive: "Hipótesis todavía sin guardar",
          previous_notes: ""
        }
      )
      |> render_change()

      view |> element("#generate-functional-analysis-draft") |> render_click()
      render_async(view)

      assert render(view) =~ "No se pudo generar el borrador E-O-R-C."

      assert has_element?(
               view,
               "#functional-analysis-response-cognitive",
               "Hipótesis todavía sin guardar"
             )
    end

    test "a citation deleted while generation runs invalidates the generated draft", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Evidencia citada que será eliminada"
        )

      test_pid = self()

      expect(Alethea.AI.FunctionalAnalysisDraftChainMock, :run, fn _params ->
        send(test_pid, {:draft_chain_waiting, self()})
        receive do: (:finish_draft_generation -> generated_eorc_fields())
      end)

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#functional-analysis-form",
        functional_analysis: %{response_cognitive: "Edición sin guardar", previous_notes: ""}
      )
      |> render_change()

      view |> element("#generate-functional-analysis-draft") |> render_click()
      assert_receive {:draft_chain_waiting, chain_pid}

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"consultation_evidence", evidence.id},
                 actor: professional,
                 trigger: "manual"
               )

      send(chain_pid, :finish_draft_generation)
      render_async(view)

      assert render(view) =~ "La evidencia citada cambió durante la generación."
      assert has_element?(view, "#functional-analysis-response-cognitive", "Edición sin guardar")
      refute render(view) =~ "IA: organism_sleep"
    end

    test "a draft deleted while generation runs is not restored in the editor", %{
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
        "Evidencia citada"
      )

      {:ok, draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Borrador antes del borrado"
        )

      test_pid = self()

      expect(Alethea.AI.FunctionalAnalysisDraftChainMock, :run, fn _params ->
        send(test_pid, {:draft_chain_waiting, self()})
        receive do: (:finish_draft_generation -> generated_eorc_fields())
      end)

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#generate-functional-analysis-draft") |> render_click()
      assert_receive {:draft_chain_waiting, chain_pid}

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_draft", draft.id},
                 actor: professional,
                 trigger: "manual"
               )

      send(chain_pid, :finish_draft_generation)
      render_async(view)

      assert has_element?(view, "#draft-tombstone")
      refute has_element?(view, "#functional-analysis-form")
      refute render(view) =~ "IA: organism_sleep"
    end
  end

  describe "autosaved E-O-R-C working draft (GitHub #362)" do
    test "autosaves clinician changes without explicit Save and survives reload", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#editor-draft-status", "Borrador vacío")
      assert has_element?(view, "#draft-status-label", "Borrador vacío")

      saving_html =
        render_change(view, "change_functional_analysis", %{
          "functional_analysis" => %{"antecedents_distal" => "Autosaved distal content"}
        })

      assert saving_html =~ "Guardando…"
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#editor-draft-status", "Guardado")
      assert has_element?(view, "#draft-status-label", "Guardado")

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_distal == "Autosaved distal content"

      {:ok, remounted_view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(
               remounted_view,
               "#functional-analysis-antecedents-distal",
               "Autosaved distal content"
             )

      assert has_element?(remounted_view, "#editor-draft-status", "Guardado")
      assert has_element?(remounted_view, "#draft-status-label", "Guardado")

      other_patient = create_patient!(professional)
      other_target = create_target_behavior!(professional, other_patient)

      {:ok, other_view, _html} =
        live(
          conn,
          ~p"/patients/#{other_patient.id}/target_behaviors/#{other_target.id}/review"
        )

      assert has_element?(other_view, "#editor-draft-status", "Borrador vacío")
      assert has_element?(other_view, "#draft-status-label", "Borrador vacío")

      refute has_element?(
               other_view,
               "#functional-analysis-antecedents-distal",
               "Autosaved distal content"
             )

      assert {:ok, nil} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 other_patient.id,
                 other_target.id
               )
    end

    test "displays saving, saved, and save failure feedback while keeping visible text intact on error",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      saving_html =
        render_change(view, "change_functional_analysis", %{
          "functional_analysis" => %{"antecedents_distal" => "Valid initial text"}
        })

      assert saving_html =~ "Guardando…"
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#editor-draft-status", "Guardado")
      assert has_element?(view, "#draft-status-label", "Guardado")

      assert {:ok, draft} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      # Simulate a write error by tombstoning the draft record in the DB
      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_draft", draft.id},
                 actor: professional,
                 trigger: "manual"
               )

      change_html =
        render_change(view, "change_functional_analysis", %{
          "functional_analysis" => %{"antecedents_distal" => "Failed text"}
        })

      assert change_html =~ "Guardando…"
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#editor-draft-status", "Error al guardar")
      assert has_element?(view, "#draft-status-label", "Error al guardar")
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Failed text")
    end

    test "concurrent tab editing detects conflict and does not silently overwrite newer edits", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      assert {:ok, _initial_draft} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"response_motor" => "Initial motor response"}
               )

      {:ok, view1, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      {:ok, view2, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_change(view2, "change_functional_analysis", %{
        "functional_analysis" => %{"response_motor" => "Tab 2 edit"}
      })

      _ = :sys.get_state(view2.pid)

      assert has_element?(view2, "#editor-draft-status", "Guardado")

      assert {:ok, draft} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert draft.lock_version == 2

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.response_motor == "Tab 2 edit"

      render_change(view1, "change_functional_analysis", %{
        "functional_analysis" => %{"response_motor" => "Tab 1 stale edit"}
      })

      _ = :sys.get_state(view1.pid)

      assert has_element?(view1, "#editor-draft-status", "Conflicto al guardar")
      assert has_element?(view1, "#draft-status-label", "Conflicto al guardar")

      assert {:ok, db_content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert db_content.response_motor == "Tab 2 edit"
      assert has_element?(view1, "#functional-analysis-response-motor", "Tab 1 stale edit")
    end

    test "older out-of-order autosave sequence message does not overwrite newer clinician edits",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_change(view, "change_functional_analysis", %{
        "functional_analysis" => %{"antecedents_distal" => "Change 1"}
      })

      _ = :sys.get_state(view.pid)

      render_change(view, "change_functional_analysis", %{
        "functional_analysis" => %{"antecedents_distal" => "Change 2"}
      })

      _ = :sys.get_state(view.pid)

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_distal == "Change 2"

      send(view.pid, {:perform_autosave, %{"antecedents_distal" => "Stale sequence 0 edit"}, 0})
      _ = :sys.get_state(view.pid)

      assert {:ok, content_after_0} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content_after_0.antecedents_distal == "Change 2"
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Change 2")

      send(view.pid, {:perform_autosave, %{"antecedents_distal" => "Stale sequence 1 edit"}, 1})
      _ = :sys.get_state(view.pid)

      assert {:ok, current_content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert current_content.antecedents_distal == "Change 2"
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Change 2")

      refute has_element?(
               view,
               "#functional-analysis-antecedents-distal",
               "Stale sequence 1 edit"
             )
    end

    test "explicit manual Save button continues to work alongside autosave", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> form("#functional-analysis-form",
          functional_analysis: %{
            antecedents_distal: "Explicit manual distal content",
            response_cognitive: "Explicit manual cognitive content"
          }
        )
        |> render_submit()

      assert html =~ "Análisis funcional guardado."
      assert has_element?(view, "#editor-draft-status", "Guardado")
      assert has_element?(view, "#draft-status-label", "Guardado")

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_distal == "Explicit manual distal content"
      assert content.response_cognitive == "Explicit manual cognitive content"
    end
  end

  describe "explicit E-O-R-C version registration (GitHub #363)" do
    @version_form "#functional-analysis-version-form"

    test "registers exactly the persisted draft with a trimmed note and keeps the editor editable",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      persist_draft!(professional, patient, target_behavior, %{
        "antecedents_distal" => "Contenido persistido"
      })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      assert has_element?(view, @version_form)
      assert has_element?(view, "#{@version_form} button[type=submit]", "Registrar versión")

      html = register_version(view, "  Primera formulación  ")

      assert html =~ "Versión 1 registrada."

      assert {:ok, [version]} =
               ClinicalRecord.list_functional_analysis_versions(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert version.version_number == 1
      assert version.change_note == "Primera formulación"
      {_format, registered} = FunctionalAnalysisContent.parse(version.body)
      assert registered.antecedents_distal == "Contenido persistido"

      # The note form is reset and the editor keeps autosaving normally.
      assert has_element?(view, "#functional-analysis-version-note[value='']")

      render_change(view, "change_functional_analysis", %{
        "functional_analysis" => %{"antecedents_distal" => "Edición posterior"}
      })

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#editor-draft-status", "Guardado")
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Edición posterior")

      # The registered snapshot is immutable; a new registration captures the new draft.
      assert register_version(view, "Segunda formulación") =~ "Versión 2 registrada."

      assert {:ok, [first, second]} =
               ClinicalRecord.list_functional_analysis_versions(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      {_, first_content} = FunctionalAnalysisContent.parse(first.body)
      {_, second_content} = FunctionalAnalysisContent.parse(second.body)
      assert first_content.antecedents_distal == "Contenido persistido"
      assert second_content.antecedents_distal == "Edición posterior"
    end

    test "rejects a blank note inline without registering anything", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      persist_draft!(professional, patient, target_behavior, %{
        "response_motor" => "Respuesta persistida"
      })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      html = register_version(view, "   ")

      assert html =~ "Ingresá una nota breve del cambio."
      assert version_count() == 0
      assert has_element?(view, "#functional-analysis-response-motor", "Respuesta persistida")
      assert has_element?(view, "#editor-draft-status", "Guardado")
    end

    test "rejects unsaved AI-generated content and preserves the editor", %{
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
        "Evidencia citada para generar"
      )

      persist_draft!(professional, patient, target_behavior, %{
        "antecedents_distal" => "Texto guardado"
      })

      expect(Alethea.AI.FunctionalAnalysisDraftChainMock, :run, fn _params ->
        generated_eorc_fields()
      end)

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      view |> element("#generate-functional-analysis-draft") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#functional-analysis-organism-sleep", "IA: organism_sleep")

      html = register_version(view, "Incluye texto de IA")

      assert html =~ "Guardá los cambios pendientes antes de registrar una versión."
      assert version_count() == 0
      assert has_element?(view, "#functional-analysis-organism-sleep", "IA: organism_sleep")
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Texto guardado")
    end

    test "rejects registration while an autosave is pending", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      persist_draft!(professional, patient, target_behavior, %{
        "antecedents_distal" => "Texto guardado"
      })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      :sys.replace_state(view.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, :draft_status, :saving)}
      end)

      html = register_version(view, "Durante el autoguardado")

      assert html =~ "Esperá a que termine el guardado antes de registrar una versión."
      assert version_count() == 0
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Texto guardado")
    end

    test "rejects registration after a failed save and keeps the unsaved edit", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      draft =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Texto guardado"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_draft", draft.id},
                 actor: professional,
                 trigger: "manual"
               )

      render_change(view, "change_functional_analysis", %{
        "functional_analysis" => %{"antecedents_distal" => "Edición que falló"}
      })

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#editor-draft-status", "Error al guardar")

      html = register_version(view, "Después del error")

      assert html =~ "Resolvé el error de guardado antes de registrar una versión."
      assert version_count() == 0
      assert has_element?(view, "#functional-analysis-antecedents-distal", "Edición que falló")
    end

    test "rejects registration in a conflicted session and preserves the stale edit", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      persist_draft!(professional, patient, target_behavior, %{"response_motor" => "Inicial"})

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      persist_draft!(professional, patient, target_behavior, %{"response_motor" => "Otra sesión"})

      render_change(view, "change_functional_analysis", %{
        "functional_analysis" => %{"response_motor" => "Edición desactualizada"}
      })

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#editor-draft-status", "Conflicto al guardar")

      html = register_version(view, "Con conflicto")

      assert html =~ "Resolvé el conflicto de guardado antes de registrar una versión."
      assert version_count() == 0
      assert has_element?(view, "#functional-analysis-response-motor", "Edición desactualizada")
      assert has_element?(view, "#editor-draft-status", "Conflicto al guardar")
    end

    test "a draft changed by another session after mount is reported as a conflict", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      persist_draft!(professional, patient, target_behavior, %{"response_motor" => "Inicial"})

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      persist_draft!(professional, patient, target_behavior, %{"response_motor" => "Otra sesión"})

      html = register_version(view, "Sobre un borrador cambiado")

      assert html =~ "Conflicto: otra sesión modificó el borrador."
      assert version_count() == 0
      assert has_element?(view, "#editor-draft-status", "Conflicto al guardar")
      assert has_element?(view, "#functional-analysis-response-motor", "Inicial")
    end

    test "hides the action and rejects a forged event for a legally deleted draft", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      draft =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Se eliminará"
        })

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_draft", draft.id},
                 actor: professional,
                 trigger: "manual"
               )

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      assert has_element?(view, "#draft-tombstone")
      refute has_element?(view, @version_form)

      html =
        render_hook(view, "register_functional_analysis_version", %{
          "version" => %{"change_note" => "Forzado"}
        })

      assert html =~ "El borrador fue eliminado legalmente."
      assert version_count() == 0
    end

    test "rejects registration when no draft was ever persisted", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      html = register_version(view, "Sin borrador")

      assert html =~ "Guardá el análisis funcional antes de registrar una versión."
      assert version_count() == 0
      assert has_element?(view, "#editor-draft-status", "Borrador vacío")
    end

    test "is only reachable through the authenticated responsible professional", %{
      patient: patient,
      target_behavior: target_behavior
    } do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(build_conn(), review_path(patient, target_behavior))

      other_conn = log_in_professional(build_conn(), create_professional!())

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(other_conn, review_path(patient, target_behavior))

      assert version_count() == 0
    end

    defp review_path(patient, target_behavior),
      do: ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review"

    defp persist_draft!(professional, patient, target_behavior, params) do
      {:ok, draft} =
        ClinicalRecord.upsert_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id,
          params
        )

      draft
    end

    defp register_version(view, note) do
      view
      |> form(@version_form, version: %{change_note: note})
      |> render_submit()
    end

    defp version_count, do: Repo.aggregate(FunctionalAnalysisVersion, :count)
  end

  describe "read-only E-O-R-C version browsing (GitHub #364)" do
    @working_draft_option "#functional-analysis-working-draft-option"
    @eorc_fields ~w(
      antecedents_distal antecedents_immediate
      organism_sleep organism_pain_or_discomfort organism_hunger_or_nutrition organism_learning_history
      response_physiological response_cognitive response_motor
      consequences_short_term consequences_long_term
    )

    test "selector always renders the working draft first, lists versions oldest-first across a legal-deletion gap, and shows only the working draft when none are registered",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      assert has_element?(view, "#{@working_draft_option}[aria-pressed=\"true\"]")
      refute has_element?(view, "[id^='functional-analysis-version-option-']")

      versions =
        for note <- ["Primera nota", "Segunda nota", "Tercera nota"] do
          draft =
            persist_draft!(professional, patient, target_behavior, %{"antecedents_distal" => note})

          {:ok, version} =
            ClinicalRecord.register_functional_analysis_version(
              professional,
              patient.id,
              target_behavior.id,
              draft.lock_version,
              note
            )

          version
        end

      [first, second, third] = versions

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_version", third.id},
                 actor: professional,
                 trigger: "manual"
               )

      fourth_draft =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Cuarta nota"
        })

      {:ok, fourth} =
        ClinicalRecord.register_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          fourth_draft.lock_version,
          "Cuarta nota"
        )

      {:ok, view2, html2} = live(conn, review_path(patient, target_behavior))

      assert has_element?(view2, "#{@working_draft_option}[aria-pressed=\"true\"]")
      refute html2 =~ ~r/\d+ of \d+/

      ordered = [first, second, fourth]
      notes = ["Primera nota", "Segunda nota", "Cuarta nota"]

      positions =
        Enum.map(ordered, fn version ->
          assert has_element?(
                   view2,
                   "#functional-analysis-version-option-#{version.id}",
                   "Versión #{version.version_number}"
                 )

          {pos, _} = :binary.match(html2, "functional-analysis-version-option-#{version.id}")
          pos
        end)

      assert positions == Enum.sort(positions)

      for {version, note} <- Enum.zip(ordered, notes) do
        assert has_element?(
                 view2,
                 "#functional-analysis-version-option-#{version.id}",
                 note
               )
      end
    end

    test "selecting a version shows all 11 E-O-R-C fields plus the full note read-only and hides every write form",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      draft = persist_draft!(professional, patient, target_behavior, eorc_params("V2"))

      {:ok, version} =
        ClinicalRecord.register_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          draft.lock_version,
          "Nota completa de la versión dos"
        )

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      view
      |> element("#functional-analysis-version-option-#{version.id}")
      |> render_click()

      assert has_element?(view, "#functional-analysis-version-view")

      for field <- @eorc_fields do
        assert has_element?(
                 view,
                 "##{field_view_id(field)}",
                 "#{field} V2"
               )
      end

      assert has_element?(
               view,
               "#functional-analysis-version-view-change-note",
               "Nota completa de la versión dos"
             )

      refute has_element?(view, "#functional-analysis-form")
      refute has_element?(view, "#functional-analysis-version-form")
      refute has_element?(view, "#generate-functional-analysis-draft")
    end

    test "returning to the working draft restores unsaved form content and the same draft status, across saved/save_failed/conflict",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      draft =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Guardado"
        })

      {:ok, version} =
        ClinicalRecord.register_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          draft.lock_version,
          "Nota"
        )

      for {status, label} <- [
            {:saved, "Guardado"},
            {:save_failed, "Error al guardar"},
            {:conflict, "Conflicto al guardar"}
          ] do
        {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

        render_change(view, "change_functional_analysis", %{
          "functional_analysis" => %{"antecedents_distal" => "Edición sin guardar #{status}"}
        })

        _ = :sys.get_state(view.pid)

        :sys.replace_state(view.pid, fn state ->
          %{state | socket: Phoenix.Component.assign(state.socket, :draft_status, status)}
        end)

        view
        |> element("#functional-analysis-version-option-#{version.id}")
        |> render_click()

        assert has_element?(view, "#functional-analysis-version-view")

        view
        |> element(@working_draft_option)
        |> render_click()

        refute has_element?(view, "#functional-analysis-version-view")

        assert has_element?(
                 view,
                 "#functional-analysis-antecedents-distal",
                 "Edición sin guardar #{status}"
               )

        assert has_element?(view, "#editor-draft-status", label)
      end
    end

    test "a legally deleted version fails selection with a generic message, keeps the working draft active, and disappears from the list",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      draft =
        persist_draft!(professional, patient, target_behavior, %{"antecedents_distal" => "Activo"})

      {:ok, version} =
        ClinicalRecord.register_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          draft.lock_version,
          "Nota"
        )

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      assert has_element?(view, "#functional-analysis-version-option-#{version.id}")

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_version", version.id},
                 actor: professional,
                 trigger: "manual"
               )

      html =
        view
        |> element("#functional-analysis-version-option-#{version.id}")
        |> render_click()

      assert html =~ "La versión no está disponible."
      refute has_element?(view, "#functional-analysis-version-view")
      assert has_element?(view, "#functional-analysis-form")
      refute has_element?(view, "#functional-analysis-version-option-#{version.id}")
    end

    test "every write path no-ops while a version is selected, and a pending generation blocks selection itself",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      draft =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Protegido"
        })

      {:ok, version} =
        ClinicalRecord.register_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          draft.lock_version,
          "Nota protegida"
        )

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      view
      |> element("#functional-analysis-version-option-#{version.id}")
      |> render_click()

      assert has_element?(view, "#functional-analysis-version-view")

      {:ok, initial_content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      forged_events = [
        {:change, "change_functional_analysis",
         %{"functional_analysis" => %{"antecedents_distal" => "Forzado"}}},
        {:hook, "save_functional_analysis",
         %{"functional_analysis" => %{"antecedents_distal" => "Forzado"}}},
        {:hook, "register_functional_analysis_version",
         %{"version" => %{"change_note" => "Forzado"}}},
        {:hook, "generate_functional_analysis_draft", %{}}
      ]

      for {kind, event, params} <- forged_events do
        case kind do
          :change -> render_change(view, event, params)
          :hook -> render_hook(view, event, params)
        end

        _ = :sys.get_state(view.pid)
      end

      assert {:ok, ^initial_content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert version_count() == 1
      assert has_element?(view, "#functional-analysis-version-view")

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.functional_analysis_lock_version == draft.lock_version
      refute state.socket.assigns.draft_generation_pending

      # Fold-in (L5): a pending generation blocks selection itself, even via a forged event.
      view
      |> element(@working_draft_option)
      |> render_click()

      :sys.replace_state(view.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, :draft_generation_pending, true)}
      end)

      html = render_hook(view, "select_functional_analysis_version", %{"id" => version.id})

      refute html =~ "functional-analysis-version-view"
      assert has_element?(view, "#functional-analysis-version-option-#{version.id}[disabled]")
    end

    defp eorc_params(marker) do
      Map.new(@eorc_fields, fn field -> {field, "#{field} #{marker}"} end)
    end

    defp field_view_id(field),
      do: "functional-analysis-version-view-#{String.replace(field, "_", "-")}"
  end

  describe "continue from a previous E-O-R-C version (GitHub #365)" do
    @continue_button "#functional-analysis-version-continue"
    @continue_confirmation "#functional-analysis-version-continue-confirmation"
    @continue_confirm "#functional-analysis-version-continue-confirm"
    @continue_cancel "#functional-analysis-version-continue-cancel"
    @eorc_fields ~w(
      antecedents_distal antecedents_immediate
      organism_sleep organism_pain_or_discomfort organism_hunger_or_nutrition organism_learning_history
      response_physiological response_cognitive response_motor
      consequences_short_term consequences_long_term
    )

    defp register_version!(professional, patient, target_behavior, marker, note) do
      draft = persist_draft!(professional, patient, target_behavior, eorc_params(marker))

      {:ok, version} =
        ClinicalRecord.register_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          draft.lock_version,
          note
        )

      version
    end

    defp open_version(view, version) do
      view
      |> element("#functional-analysis-version-option-#{version.id}")
      |> render_click()
    end

    test "blank working draft applies the copy immediately with no confirmation (C2, C5, C7)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      blank_params = Map.new(@eorc_fields, fn field -> {field, ""} end)
      _reset = persist_draft!(professional, patient, target_behavior, blank_params)

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      assert has_element?(view, "#functional-analysis-version-view")

      html =
        view
        |> element(@continue_button)
        |> render_click()

      refute html =~ "functional-analysis-version-continue-confirmation"

      assert html =~
               "Contenido de la Versión #{version.version_number} copiado al borrador de trabajo."

      refute has_element?(view, "#functional-analysis-version-view")

      _ = :sys.get_state(view.pid)

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      for field <- @eorc_fields do
        assert Map.get(content, String.to_existing_atom(field)) == "#{field} V2"
      end

      assert version_count() == 1
    end

    test "non-blank working draft requires confirmation before any write (C3, C1)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)

      html =
        view
        |> element(@continue_button)
        |> render_click()

      assert html =~ "Versión #{version.version_number}"
      assert html =~ "será reemplazado"
      refute has_element?(view, @continue_button)
      assert has_element?(view, @continue_confirm)
      assert has_element?(view, @continue_cancel)

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content.antecedents_distal == "Trabajo actual"
      assert version_count() == 1
    end

    test "confirming continuation copies the version via the real autosave path (C4, C5, C7)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      {:ok, original_version} =
        ClinicalRecord.get_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          version.id
        )

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      view |> element(@continue_button) |> render_click()

      html = view |> element(@continue_confirm) |> render_click()

      refute html =~ "id=\"functional-analysis-version-view\""
      refute has_element?(view, "#functional-analysis-version-view")
      assert has_element?(view, "#functional-analysis-form")

      for field <- @eorc_fields do
        assert has_element?(view, "##{form_field_id(field)}", "#{field} V2")
      end

      _ = :sys.get_state(view.pid)

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      for field <- @eorc_fields do
        assert Map.get(content, String.to_existing_atom(field)) == "#{field} V2"
      end

      assert version_count() == 1

      {:ok, reloaded_version} =
        ClinicalRecord.get_functional_analysis_version(
          professional,
          patient.id,
          target_behavior.id,
          version.id
        )

      assert reloaded_version.body == original_version.body
    end

    test "cancel discards only the pending confirmation (C6)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      view |> element(@continue_button) |> render_click()

      html = view |> element(@continue_cancel) |> render_click()

      refute html =~ "functional-analysis-version-continue-confirmation"
      assert has_element?(view, "#functional-analysis-version-view")
      assert has_element?(view, @continue_button)

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content.antecedents_distal == "Trabajo actual"
      assert version_count() == 1
    end

    test "conflict blocks both request and a forged confirm (C8)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)

      :sys.replace_state(view.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, :draft_status, :conflict)}
      end)

      html = view |> element(@continue_button) |> render_click()

      assert html =~ "Resolvé el conflicto de guardado antes de continuar desde una versión."
      refute has_element?(view, @continue_confirmation)

      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: Phoenix.Component.assign(state.socket, :continue_confirmation_pending, true)
        }
      end)

      html = render_hook(view, "confirm_continue_from_version", %{})

      assert html =~ "Resolvé el conflicto de guardado antes de continuar desde una versión."

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content.antecedents_distal == "Trabajo actual"
      assert version_count() == 1
    end

    test "saving/save_failed with a queued stale autosave is superseded by the copy (C8, AD2)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      for status <- [:saving, :save_failed] do
        version =
          register_version!(
            professional,
            patient,
            target_behavior,
            "V#{status}",
            "Nota #{status}"
          )

        _current =
          persist_draft!(professional, patient, target_behavior, %{
            "antecedents_distal" => "Trabajo actual #{status}"
          })

        {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

        render_change(view, "change_functional_analysis", %{
          "functional_analysis" => %{"antecedents_distal" => "Edicion sin guardar #{status}"}
        })

        :sys.replace_state(view.pid, fn state ->
          %{state | socket: Phoenix.Component.assign(state.socket, :draft_status, status)}
        end)

        open_version(view, version)
        view |> element(@continue_button) |> render_click()
        view |> element(@continue_confirm) |> render_click()

        _ = :sys.get_state(view.pid)

        {:ok, content} =
          ClinicalRecord.get_functional_analysis_content(
            professional,
            patient.id,
            target_behavior.id
          )

        assert content.antecedents_distal == "antecedents_distal V#{status}"
      end
    end

    test "a version deleted between request and confirm fails generically and disappears from the list (C4)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version = register_version!(professional, patient, target_behavior, "V2", "Nota protegida")

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      view |> element(@continue_button) |> render_click()

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_version", version.id},
                 actor: professional,
                 trigger: "manual"
               )

      html = view |> element(@continue_confirm) |> render_click()

      assert html =~ "La versión no está disponible."
      refute html =~ "V2"
      refute has_element?(view, "#functional-analysis-version-option-#{version.id}")

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content.antecedents_distal == "Trabajo actual"
    end

    test "losing authorization between request and confirm redirects without copying", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      view |> element(@continue_button) |> render_click()

      other_professional = create_professional!()

      patient
      |> Ecto.Changeset.change(professional_id: other_professional.id)
      |> Repo.update!()

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               view
               |> element(@continue_confirm)
               |> render_click()

      patient
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:professional_id, professional.id)
      |> Repo.update!()

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content.antecedents_distal == "Trabajo actual"
    end

    test "forged request/confirm while tombstoned, no selection, or generation pending is a no-op (C10)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      {:ok, initial_content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      base_seq = :sys.get_state(view.pid).socket.assigns.autosave_seq

      # Table-driven, mirrors #364's forged-event block (:2162-2179): each
      # case sets up one blocked precondition, fires both forged events, and
      # the shared assertions below confirm none of them wrote anything.
      forged_cases = [
        {"no version selected", fn -> :ok end},
        {"draft tombstoned",
         fn ->
           open_version(view, version)

           :sys.replace_state(view.pid, fn state ->
             %{
               state
               | socket:
                   Phoenix.Component.assign(
                     state.socket,
                     :draft_tombstoned_at,
                     DateTime.utc_now()
                   )
             }
           end)
         end},
        {"generation pending",
         fn ->
           :sys.replace_state(view.pid, fn state ->
             state.socket
             |> Phoenix.Component.assign(:draft_tombstoned_at, nil)
             |> Phoenix.Component.assign(:draft_generation_pending, true)
             |> then(&%{state | socket: &1})
           end)
         end}
      ]

      for {_label, setup} <- forged_cases do
        setup.()
        render_hook(view, "request_continue_from_version", %{})
        render_hook(view, "confirm_continue_from_version", %{})
        _ = :sys.get_state(view.pid)
      end

      assert {:ok, ^initial_content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert version_count() == 1

      final_state = :sys.get_state(view.pid)
      assert final_state.socket.assigns.autosave_seq == base_seq
    end

    test "changing selection discards a pending confirmation so a later forged confirm writes nothing (C9)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      other_version =
        register_version!(professional, patient, target_behavior, "V3", "Nota version tres")

      _current =
        persist_draft!(professional, patient, target_behavior, %{
          "antecedents_distal" => "Trabajo actual"
        })

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      view |> element(@continue_button) |> render_click()
      assert has_element?(view, @continue_confirmation)

      open_version(view, other_version)
      refute has_element?(view, @continue_confirmation)

      render_hook(view, "confirm_continue_from_version", %{})
      _ = :sys.get_state(view.pid)

      {:ok, content} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content.antecedents_distal == "Trabajo actual"

      view |> element(@continue_button) |> render_click()
      assert has_element?(view, @continue_confirmation)

      view
      |> element(@working_draft_option)
      |> render_click()

      refute has_element?(view, @continue_confirmation)

      render_hook(view, "confirm_continue_from_version", %{})
      _ = :sys.get_state(view.pid)

      {:ok, content_after} =
        ClinicalRecord.get_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id
        )

      assert content_after.antecedents_distal == "Trabajo actual"
      assert version_count() == 2
    end

    test "AC5: reload shows the copied working draft and the historical version is unchanged (C7)",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      version =
        register_version!(professional, patient, target_behavior, "V2", "Nota version dos")

      blank_params = Map.new(@eorc_fields, fn field -> {field, ""} end)
      _reset = persist_draft!(professional, patient, target_behavior, blank_params)

      {:ok, view, _html} = live(conn, review_path(patient, target_behavior))

      open_version(view, version)
      view |> element(@continue_button) |> render_click()
      _ = :sys.get_state(view.pid)

      {:ok, reload_view, _html} = live(conn, review_path(patient, target_behavior))

      for field <- @eorc_fields do
        assert has_element?(reload_view, "##{form_field_id(field)}", "#{field} V2")
      end

      open_version(reload_view, version)

      for field <- @eorc_fields do
        assert has_element?(reload_view, "##{field_view_id(field)}", "#{field} V2")
      end

      assert has_element?(
               reload_view,
               "#functional-analysis-version-view-change-note",
               "Nota version dos"
             )
    end

    defp form_field_id(field), do: "functional-analysis-#{String.replace(field, "_", "-")}"
  end

  describe "structured functional-analysis draft and explicit note creation" do
    test "saving structured analysis persists it without creating a clinical note", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> form("#functional-analysis-form",
          functional_analysis: %{
            antecedents_immediate: "Pedido inesperado",
            response_motor: "Evitó la tarea"
          }
        )
        |> render_submit()

      assert html =~ "Análisis funcional guardado."
      assert Repo.aggregate(ClinicalNote, :count) == 0

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_immediate == "Pedido inesperado"
      assert content.response_motor == "Evitó la tarea"
    end

    test "no longer offers duplicated clinical note form", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, "#note-form")
    end

    test "editor exposes guided E-O-R-C sections and stable fields", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#functional-analysis-form")
      assert has_element?(view, "#functional-analysis-antecedents")
      assert has_element?(view, "#functional-analysis-organism")
      assert has_element?(view, "#functional-analysis-response")
      assert has_element?(view, "#functional-analysis-consequences")
      assert has_element?(view, "#functional-analysis-antecedents-immediate")
      assert has_element?(view, "#functional-analysis-response-motor")
    end

    test "structured editor is ready without loading a draft template", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#functional-analysis-antecedents-distal")
      assert has_element?(view, "#functional-analysis-organism-learning-history")
      assert has_element?(view, "#functional-analysis-response-cognitive")
      assert has_element?(view, "#functional-analysis-consequences-long-term")
      assert has_element?(view, "#save-functional-analysis")
    end
  end

  describe "post-deletion tombstone rendering (BR10, sdd/clinical-record-retention, GitHub #197)" do
    test "a tombstoned entry renders content-free as legally deleted on {date}, ordered chronologically",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)
      t1 = ~U[2026-01-01 10:00:00.000000Z]
      t2 = ~U[2026-01-01 11:00:00Z]
      t3 = ~U[2026-01-01 12:00:00.000000Z]

      insert_evidence!(
        professional,
        patient,
        target_behavior,
        dek,
        t1,
        "clinical_note",
        Ecto.UUID.generate(),
        "Evidencia antes del borrado"
      )

      insert_tombstone!(patient, target_behavior, t2, "clinician_observation")

      insert_proposal!(
        professional,
        patient,
        target_behavior,
        dek,
        t3,
        "Propuesta despues del borrado"
      )

      {:ok, _view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert html =~ "Eliminado legalmente el"
      assert html =~ "01/01/2026"

      evidence_pos = :binary.match(html, "Evidencia antes del borrado") |> elem(0)
      tombstone_pos = :binary.match(html, "Eliminado legalmente el") |> elem(0)
      proposal_pos = :binary.match(html, "Propuesta despues del borrado") |> elem(0)

      assert evidence_pos < tombstone_pos
      assert tombstone_pos < proposal_pos
    end

    test "content that was legally deleted no longer renders; only the tombstone appears", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      dek = load_dek!(professional, patient)

      observation =
        insert_observation!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "Observacion a eliminar legalmente"
        )

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"clinician_observation", observation.id},
                 actor: professional,
                 trigger: "manual"
               )

      {:ok, _view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute html =~ "Observacion a eliminar legalmente"
      assert html =~ "Eliminado legalmente el"
    end
  end

  describe "functional-analysis draft distinguishes legally-deleted from never-created (BR10, GitHub #197)" do
    test "a legally deleted draft is reported distinctly from an unset draft and renders content-free",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Borrador a eliminar legalmente"
        )

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"functional_analysis_draft", draft.id},
                 actor: professional,
                 trigger: "manual"
               )

      assert {:ok, {:legally_deleted, deleted_at}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert %DateTime{} = deleted_at

      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute html =~ "Borrador a eliminar legalmente"
      assert has_element?(view, "#draft-tombstone")
    end

    test "a target behavior with no draft ever saved still returns {:ok, nil}", %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      assert {:ok, nil} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end
  end

  describe "clinical workbench header & counters (GitHub #290)" do
    test "displays patient alias, target behavior description, and initial counters", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#clinical-workbench-header")
      assert has_element?(view, "#patient-alias", patient.alias)
      assert has_element?(view, "#target-behavior-description", "Conducta objetivo")
      assert has_element?(view, "#stat-evidence .stat-tile__value", "0")
      assert has_element?(view, "#stat-observations .stat-tile__value", "0")
      assert has_element?(view, "#stat-proposals .stat-tile__value", "0")
      assert has_element?(view, "#draft-status-label", "Borrador vacío")
      assert html =~ patient.alias
      assert html =~ "Conducta objetivo"
    end

    test "counters reflect evidence, observations, proposals, and draft status", %{
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
        ~U[2026-01-01 10:00:00.000000Z],
        "clinical_note",
        Ecto.UUID.generate(),
        "Evidencia 1"
      )

      insert_observation!(
        professional,
        patient,
        target_behavior,
        dek,
        ~U[2026-01-01 11:00:00.000000Z],
        "Observacion 1"
      )

      insert_proposal!(
        professional,
        patient,
        target_behavior,
        dek,
        ~U[2026-01-01 12:00:00.000000Z],
        "Propuesta 1"
      )

      {:ok, _draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Hipotesis inicial guardada"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#stat-evidence .stat-tile__value", "1")
      assert has_element?(view, "#stat-observations .stat-tile__value", "1")
      assert has_element?(view, "#stat-proposals .stat-tile__value", "1")
      assert has_element?(view, "#draft-status-label", "Guardado")
    end

    test "draft counter reflects legally deleted status", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      insert_tombstone!(
        patient,
        target_behavior,
        DateTime.utc_now() |> DateTime.truncate(:second),
        "functional_analysis_draft"
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#draft-status-label", "Eliminado legalmente")
    end
  end

  describe "evidence citation flow (GitHub #306)" do
    test "offers primary actions in the header and consolidated actionable guidance", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#cite-evidence-header", "Citar evidencia")
      assert has_element?(view, "#evidence-guide")
      assert has_element?(view, "#cite-evidence-guide", "Citar evidencia")
      refute has_element?(view, "#empty-evidence")
      refute has_element?(view, "#empty-proposals")
      assert has_element?(view, "#functional-analysis-form")
    end

    test "guides the clinician to suggest patterns when evidence exists but proposals do not", %{
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
        "Evidencia suficiente para sugerir patrones"
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#evidence-guide")
      assert has_element?(view, "#suggest-patterns-guide.button-primary", "Sugerir patrones (IA)")
      refute has_element?(view, "#evidence-guide #cite-evidence-guide")
      refute has_element?(view, "#cite-evidence-header.button-primary")
      assert has_element?(view, "#functional-analysis-form")
    end

    test "opening shows every full source in an accessible feed and preserves domain order",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      {:ok, note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Nota clínica completa")

      inbound =
        insert_message_source!(
          patient,
          dek,
          "inbound",
          "Mensaje entrante completo del paciente",
          ~U[2026-09-16 09:00:00Z],
          "spontaneous"
        )

      outbound =
        insert_message_source!(
          patient,
          dek,
          "outbound",
          "Respuesta saliente completa",
          ~U[2026-09-16 11:00:00Z],
          "elicited"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html = view |> element("#cite-evidence-header") |> render_click()

      assert has_element?(view, "#evidence-citation-flow")

      assert has_element?(
               view,
               "#evidence-source-feed[aria-labelledby='evidence-source-feed-label'][aria-describedby='evidence-source-feed-description']"
             )

      assert has_element?(view, "#evidence-source-feed-label", "Fuentes disponibles")

      assert has_element?(
               view,
               "#evidence-source-feed-description",
               "contenido completo"
             )

      assert has_element?(
               view,
               "#evidence-source-#{inbound.id}.evidence-source-card--inbound .evidence-source-card__content",
               "Mensaje entrante completo del paciente"
             )

      assert has_element?(
               view,
               "#evidence-source-#{inbound.id} .evidence-source-card__type",
               "Mensaje entrante"
             )

      assert has_element?(
               view,
               "#evidence-source-#{inbound.id} .evidence-source-card__provenance",
               "espontáneo"
             )

      assert has_element?(
               view,
               "#evidence-source-#{outbound.id}.evidence-source-card--outbound .evidence-source-card__content",
               "Respuesta saliente completa"
             )

      assert has_element?(
               view,
               "#evidence-source-#{outbound.id} .evidence-source-card__type",
               "Mensaje saliente"
             )

      assert has_element?(
               view,
               "#evidence-source-#{outbound.id} .evidence-source-card__provenance",
               "provocado"
             )

      assert has_element?(
               view,
               "#evidence-source-#{note.id}.evidence-source-card--clinical-note .evidence-source-card__content",
               "Nota clínica completa"
             )

      assert has_element?(
               view,
               "#evidence-source-#{note.id} .evidence-source-card__type",
               "Nota clínica"
             )

      assert has_element?(
               view,
               "#evidence-source-#{note.id} .evidence-source-card__provenance",
               "registro profesional"
             )

      assert has_element?(
               view,
               "#evidence-source-#{inbound.id} .evidence-source-card__date",
               "16/09/2026 09:00"
             )

      assert has_element?(
               view,
               "#evidence-source-#{outbound.id} .evidence-source-card__date",
               "16/09/2026 11:00"
             )

      assert has_element?(view, "#evidence-source-#{note.id} .evidence-source-card__date")
      refute has_element?(view, "#evidence-source-load-more")
      refute has_element?(view, "[data-role='evidence-source-load-more']")
      refute has_element?(view, "#evidence-source-feed button", "Cargar más")

      assert {:ok, domain_sources} =
               ClinicalRecord.list_evidence_sources(professional, patient.id)

      rendered_positions =
        Enum.map(domain_sources, fn source ->
          :binary.match(html, ~s(id="evidence-source-#{source.id}")) |> elem(0)
        end)

      assert rendered_positions == Enum.sort(rendered_positions)

      view
      |> element("#evidence-source-#{inbound.id}")
      |> render_click()

      assert has_element?(
               view,
               "#evidence-source-content",
               "Mensaje entrante completo del paciente"
             )

      assert has_element?(view, "form#evidence-excerpt-form")
    end

    test "excerpt review is explicit and only final confirmation persists and refreshes the UI",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, note} =
        ClinicalRecord.create_clinical_note(
          professional,
          patient.id,
          "La paciente reporta sueño interrumpido durante tres noches."
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#cite-evidence-header") |> render_click()
      view |> element("#evidence-source-#{note.id}") |> render_click()

      view
      |> form("#evidence-excerpt-form", citation: %{excerpt: "sueño interrumpido"})
      |> render_submit()

      assert Repo.aggregate(ConsultationEvidence, :count) == 0
      assert has_element?(view, "#evidence-citation-confirmation")
      assert has_element?(view, "#citation-confirm-source", "Nota clínica")
      assert has_element?(view, "#citation-confirm-date")
      assert has_element?(view, "#citation-confirm-excerpt", "sueño interrumpido")

      assert has_element?(
               view,
               "#citation-confirm-destination",
               target_behavior.description || "Conducta objetivo"
             )

      view |> element("#confirm-evidence-citation") |> render_click()

      assert Repo.aggregate(ConsultationEvidence, :count) == 1
      refute has_element?(view, "#evidence-citation-flow")
      assert has_element?(view, "#stat-evidence .stat-tile__value", "1")
      refute has_element?(view, "#suggest-patterns[disabled]")
      assert has_element?(view, ".review-item--evidence", "sueño interrumpido")
    end

    test "cancelling selection, excerpt, or confirmation clears state without citation side effects",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, note} =
        ClinicalRecord.create_clinical_note(
          professional,
          patient.id,
          "Contenido exacto para citar"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#cite-evidence-header") |> render_click()
      view |> element("#cancel-evidence-citation") |> render_click()
      refute has_element?(view, "#evidence-citation-flow")

      view |> element("#cite-evidence-header") |> render_click()
      view |> element("#evidence-source-#{note.id}") |> render_click()
      view |> element("#cancel-evidence-citation") |> render_click()
      refute has_element?(view, "#evidence-citation-flow")

      view |> element("#cite-evidence-header") |> render_click()
      view |> element("#evidence-source-#{note.id}") |> render_click()

      view
      |> form("#evidence-excerpt-form", citation: %{excerpt: "exacto"})
      |> render_submit()

      view |> element("#cancel-evidence-citation") |> render_click()

      refute has_element?(view, "#evidence-citation-flow")
      assert Repo.aggregate(ConsultationEvidence, :count) == 0

      refute Enum.any?(all_enqueued(worker: ClinicalRecordOutboxWorker), fn job ->
               job.args["event"] == "consultation_evidence_created"
             end)
    end

    test "a source removed before final confirmation shows an error and preserves confirmation state",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Fuente que será retirada")

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#cite-evidence-header") |> render_click()
      view |> element("#evidence-source-#{note.id}") |> render_click()

      view
      |> form("#evidence-excerpt-form", citation: %{excerpt: "será retirada"})
      |> render_submit()

      Repo.delete!(note)
      view |> element("#confirm-evidence-citation") |> render_click()

      assert has_element?(view, "#evidence-citation-error")
      assert has_element?(view, "#evidence-citation-confirmation")
      assert has_element?(view, "#citation-confirm-excerpt", "será retirada")
      assert Repo.aggregate(ConsultationEvidence, :count) == 0
    end

    test "invalid or forged citation state shows an error and preserves useful source state", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Texto autorizado exacto")

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#cite-evidence-header") |> render_click()

      render_click(view, "select_evidence_source", %{
        "kind" => "message",
        "id" => Ecto.UUID.generate()
      })

      assert has_element?(view, "#evidence-citation-error")
      assert has_element?(view, "#evidence-source-list")

      view |> element("#evidence-source-#{note.id}") |> render_click()

      view
      |> form("#evidence-excerpt-form", citation: %{excerpt: "texto con mayúsculas distintas"})
      |> render_submit()

      assert has_element?(view, "#evidence-citation-error")
      assert has_element?(view, "#evidence-source-content", "Texto autorizado exacto")
      assert Repo.aggregate(ConsultationEvidence, :count) == 0
    end
  end

  describe "explicit empty states (GitHub #290)" do
    test "renders consolidated evidence/proposal guidance plus observation and draft empty states",
         %{
           conn: conn,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#evidence-guide")
      refute has_element?(view, "#empty-evidence")
      refute has_element?(view, "#empty-proposals")

      view |> element("#input-tab-observations") |> render_click()

      assert has_element?(view, "#empty-observations")

      assert has_element?(
               view,
               "#empty-observations .empty-state__title",
               "Sin observaciones del clínico"
             )

      assert has_element?(view, "#empty-draft")

      assert has_element?(
               view,
               "#empty-draft .empty-state__title",
               "Sin análisis funcional guardado"
             )

      assert has_element?(view, "#functional-analysis-form")
    end

    test "empty states disappear as items are populated or created", %{
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
        "Evidencia previa"
      )

      insert_proposal!(
        professional,
        patient,
        target_behavior,
        dek,
        DateTime.utc_now(),
        "Propuesta previa"
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, "#evidence-guide")
      refute has_element?(view, "#empty-evidence")
      refute has_element?(view, "#empty-proposals")

      view |> element("#input-tab-observations") |> render_click()

      assert has_element?(view, "#empty-observations")
      assert has_element?(view, "#empty-draft")

      # Adding an observation removes the observations empty state
      view |> element("#toggle-observation-form") |> render_click()

      view
      |> form("#observation-form", %{"observation" => %{"body" => "Nueva observacion"}})
      |> render_submit()

      refute has_element?(view, "#empty-observations")
      assert has_element?(view, "#stat-observations .stat-tile__value", "1")

      # Saving structured analysis removes the draft empty state
      view
      |> form("#functional-analysis-form", %{
        "functional_analysis" => %{"response_motor" => "Evitó la tarea"}
      })
      |> render_submit()

      refute has_element?(view, "#empty-draft")
      assert has_element?(view, "#draft-status-label", "Guardado")
    end
  end

  describe "AI pattern suggestion guards and hints (GitHub #290)" do
    test "suggest_patterns button is disabled with explanatory hint when evidence is insufficient",
         %{
           conn: conn,
           patient: patient,
           target_behavior: target_behavior
         } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#suggest-patterns[disabled]")
      assert has_element?(view, "#ai-insufficient-evidence-hint")
      assert has_element?(view, "#ai-insufficient-evidence-hint", "Requiere evidencia citada")

      # Direct event dispatch without evidence is rejected with an error flash
      html = render_click(view, "suggest_patterns", %{})
      assert html =~ "No hay evidencia clínica suficiente"
      assert all_enqueued(worker: "AletheaJobs.AIProposalWorker") == []
    end

    test "suggest_patterns button is enabled and hint is hidden when sufficient evidence exists",
         %{
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
        "Evidencia clínica para habilitar IA"
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, "#suggest-patterns[disabled]")
      refute has_element?(view, "#ai-insufficient-evidence-hint")

      html =
        view
        |> element("#suggest-patterns")
        |> render_click()

      assert_enqueued(worker: "AletheaJobs.AIProposalWorker")
      assert has_element?(view, "#suggest-patterns[disabled]")
      assert html =~ "Generando"
      assert html =~ "Generación de patrones solicitada."
    end
  end

  describe "contextual action feedback and soft confirmation (GitHub #290)" do
    test "saving an edited proposal displays info flash", %{
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
          "Texto antes de editar"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> element("button[phx-click='start_edit_proposal'][phx-value-id='#{proposal.id}']")
      |> render_click()

      html =
        view
        |> form("#edit-proposal-#{proposal.id}", %{
          "proposal" => %{"text" => "Texto editado con feedback"}
        })
        |> render_submit()

      assert html =~ "Propuesta editada."
    end

    test "accepting a proposal keeps it for manual placement and displays specific info flash", %{
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
          "Patron a incorporar al borrador"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> element("button[phx-click='accept_proposal'][phx-value-id='#{proposal.id}']")
        |> render_click()

      assert html =~
               "Propuesta aceptada. Permanece disponible para clasificación y ubicación manual."
    end

    test "accepting a proposal when draft is legally deleted still changes only proposal status",
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
          "Patron con borrador eliminado"
        )

      insert_tombstone!(
        patient,
        target_behavior,
        DateTime.utc_now() |> DateTime.truncate(:second),
        "functional_analysis_draft"
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      html =
        view
        |> element("button[phx-click='accept_proposal'][phx-value-id='#{proposal.id}']")
        |> render_click()

      assert html =~
               "Propuesta aceptada. Permanece disponible para clasificación y ubicación manual."

      assert Repo.get!(AIProposal, proposal.id).status == "accepted"
      assert has_element?(view, "#draft-tombstone")
    end

    test "discarding a proposal displays info flash and button carries data-confirm", %{
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

      assert has_element?(
               view,
               "button[phx-click='discard_proposal'][phx-value-id='#{proposal.id}'][data-confirm]"
             )

      html =
        view
        |> element("button[phx-click='discard_proposal'][phx-value-id='#{proposal.id}']")
        |> render_click()

      assert html =~ "Propuesta descartada."
    end

    test "adding clinician observation displays info flash", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view |> element("#toggle-observation-form") |> render_click()

      html =
        view
        |> form("#observation-form", %{"observation" => %{"body" => "Observacion con feedback"}})
        |> render_submit()

      assert html =~ "Observación clínica agregada."
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

  describe "suggested evidence candidates — asynchronous top 5 background loading (#321)" do
    test "cites an eligible suggestion through the encrypted boundary and refreshes the workbench",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      content = "Crisis de angustia con taquicardia en lugares cerrados"

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, content)

      {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, content)
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now(),
          source_resource_id: note.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      action = "#cite-suggested-candidate-#{candidate.id}"
      assert has_element?(view, action, "+ Citar todo")

      render_click(view, "cite_suggested_candidate", %{
        "id" => candidate.id,
        "content" => "plaintext supplied by an untrusted client"
      })

      evidence = Repo.one!(ConsultationEvidence)
      assert evidence.source_kind == "clinical_note"
      assert evidence.source_id == note.id
      assert evidence.encryption_version == 2
      refute evidence.encrypted_excerpt == content

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, ^content} =
               PatientVault.decrypt(evidence.encrypted_excerpt, clinical_record_dek)

      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
      assert has_element?(view, "#stat-evidence .stat-tile__value", "1")
      assert has_element?(view, ".review-item--evidence", content)
    end

    test "cites a patient message suggestion with message provenance and encrypted server content",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      content = "La paciente reporta angustia y taquicardia en lugares cerrados"

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, content)

      source =
        insert_message_source!(
          patient,
          load_dek!(professional, patient),
          "inbound",
          content,
          DateTime.utc_now(),
          "spontaneous"
        )

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "patient_message",
          DateTime.utc_now(),
          source_resource_id: source.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      action = "#cite-suggested-candidate-#{candidate.id}"
      assert has_element?(view, action, "+ Citar todo")

      render_click(view, "cite_suggested_candidate", %{
        "id" => candidate.id,
        "content" => "forged client plaintext"
      })

      evidence = Repo.one!(ConsultationEvidence)
      assert evidence.source_kind == "message"
      assert evidence.source_id == source.id
      refute evidence.encrypted_excerpt == content

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, ^content} =
               PatientVault.decrypt(evidence.encrypted_excerpt, clinical_record_dek)

      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
    end

    test "mounts immediately without blocking and shows loading state", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#clinical-workbench-header")
      assert has_element?(view, "#review-timeline")
      assert has_element?(view, "#suggested-candidates-loading") or html =~ "suggested-candidates"
    end

    test "renders top 5 candidate cards upon arrival with affinity badges, source kinds, and occurred times",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      description = "Crisis de angustia y taquicardia en lugares cerrados"

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, description)

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(description, [])

      t0 = ~U[2026-03-01 10:00:00.000000Z]

      for i <- 1..6 do
        occurred_at = DateTime.add(t0, i, :hour)
        resource_type = if rem(i, 2) == 0, do: "patient_message", else: "clinical_note"
        text = "Fragmento clinico #{i}: angustia y palpitaciones intensas"

        insert_rag_chunk!(
          professional,
          patient,
          text,
          query_vector,
          resource_type,
          occurred_at
        )
      end

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      _rendered = render_async(view)

      assert has_element?(view, "#suggested-candidates-list article:nth-child(5)")
      refute has_element?(view, "#suggested-candidates-list article:nth-child(6)")

      for position <- 1..5 do
        card_selector = "#suggested-candidates-list article:nth-child(#{position})"

        assert element(view, "#{card_selector} .badge--affinity") |> render() =~ "Alta afinidad"

        assert element(view, "#{card_selector} .badge--source-kind") |> render() =~
                 ~r/Nota clínica|Mensaje del paciente/

        assert has_element?(view, "#{card_selector} .suggested-candidate-card__time")

        assert element(view, "#{card_selector} .suggested-candidate-card__content") |> render() =~
                 "Fragmento clinico"

        assert has_element?(
                 view,
                 "#{card_selector} button[phx-click='cite_suggested_candidate']",
                 "+ Citar todo"
               )
      end
    end

    test "does not offer citation for suggestion source kinds unsupported by the domain boundary",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      description = "Crisis de angustia y taquicardia en lugares cerrados"

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, description)

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(description, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          "Observación clínica sobre angustia y taquicardia",
          query_vector,
          "clinician_observation",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#suggested-candidate-#{candidate.id}")
      refute has_element?(view, "#cite-suggested-candidate-#{candidate.id}")
      assert has_element?(view, "#dismiss-suggested-candidate-#{candidate.id}", "Descartar ✕")
    end

    test "renders clean empty state when no eligible candidates are available", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#suggested-candidates-empty")

      assert element(view, "#suggested-candidates-empty") |> render() =~
               "No hay sugerencias disponibles"

      refute has_element?(view, "#suggested-candidates-list")
    end

    test "renders clean empty state when target behavior has blank description", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, "   ")

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#suggested-candidates-empty")
      refute has_element?(view, "#suggested-candidates-list")
    end
  end

  describe "interactive dismissal of evidence suggestions (#324)" do
    test "each suggestion card displays a [Descartar ✕] action", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      content = "Crisis de angustia con taquicardia en lugares cerrados"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      dismiss_action = "#dismiss-suggested-candidate-#{candidate.id}"
      assert has_element?(view, dismiss_action, "Descartar ✕")
    end

    test "dismissing a suggestion records dismissal in database, displays flash, and removes the card",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content = "Crisis de angustia con taquicardia en lugares cerrados"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      dismiss_action = "#dismiss-suggested-candidate-#{candidate.id}"
      assert has_element?(view, dismiss_action)

      render_click(view, "dismiss_suggested_candidate", %{"id" => candidate.id})

      dismissal = Repo.one!(DismissedEvidenceSuggestion)
      assert dismissal.target_behavior_id == target_behavior.id
      assert dismissal.patient_id == patient.id
      assert dismissal.professional_id == professional.id
      assert dismissal.chunk_id == candidate.id

      audit =
        Repo.one!(
          from(a in Audit,
            where: a.action == "evidence_suggestion_dismissed" and a.resource_id == ^dismissal.id
          )
        )

      assert audit.resource_type == "dismissed_evidence_suggestion"
      assert audit.professional_id == professional.id
      assert audit.details["outcome"] == "success"

      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
      assert has_element?(view, "#suggested-candidates-empty")
      assert render(view) =~ "Sugerencia descartada."
    end

    test "reloading the page or revisiting the target behavior does not display the dismissed chunk again",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content1 = "Crisis de angustia con taquicardia en lugares cerrados"
      content2 = "Otra conducta de agorafobia en transporte público"
      {:ok, query_vector1} = Alethea.AI.Embeddings.Fake.embed(content1, [])
      {:ok, query_vector2} = Alethea.AI.Embeddings.Fake.embed(content2, [])

      candidate1 =
        insert_rag_chunk!(
          professional,
          patient,
          content1,
          query_vector1,
          "clinical_note",
          DateTime.utc_now()
        )

      candidate2 =
        insert_rag_chunk!(
          professional,
          patient,
          content2,
          query_vector2,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#suggested-candidate-#{candidate1.id}")
      assert has_element?(view, "#suggested-candidate-#{candidate2.id}")

      render_click(view, "dismiss_suggested_candidate", %{"id" => candidate1.id})

      refute has_element?(view, "#suggested-candidate-#{candidate1.id}")
      assert has_element?(view, "#suggested-candidate-#{candidate2.id}")

      # Reload the page
      {:ok, view_reloaded, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view_reloaded)

      refute has_element?(view_reloaded, "#suggested-candidate-#{candidate1.id}")
      assert has_element?(view_reloaded, "#suggested-candidate-#{candidate2.id}")
    end

    test "dismisses a non-citable suggestion card via interactive button click", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      description = "Crisis de angustia y taquicardia en lugares cerrados"

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, description)

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(description, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          "Observación clínica sobre angustia y taquicardia",
          query_vector,
          "clinician_observation",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#suggested-candidate-#{candidate.id}")
      refute has_element?(view, "#cite-suggested-candidate-#{candidate.id}")

      dismiss_btn = element(view, "#dismiss-suggested-candidate-#{candidate.id}")
      assert render(dismiss_btn) =~ "Descartar ✕"

      render_click(dismiss_btn)

      assert Repo.aggregate(DismissedEvidenceSuggestion, :count) == 1
      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
      assert has_element?(view, "#suggested-candidates-empty")
      assert render(view) =~ "Sugerencia descartada."
    end

    test "rejects untrusted or unmatched chunk ids with an error flash", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      forged_id = Ecto.UUID.generate()

      render_click(view, "dismiss_suggested_candidate", %{"id" => forged_id})

      assert Repo.aggregate(DismissedEvidenceSuggestion, :count) == 0
      assert render(view) =~ "No se pudo descartar la sugerencia de evidencia."
    end
  end

  describe "evidence semantic search bar (#322)" do
    test "renders the debounced search input above the evidence candidates", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#suggested-evidence-panel #evidence-search-bar")

      assert has_element?(
               view,
               "#evidence-search-input[placeholder='Buscar en el historial clínico (ej. angustia en el supermercado)…'][phx-debounce='400']"
             )
    end

    test "searches asynchronously and renders matching chunks with provenance metadata", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      query = "angustia en el supermercado"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])
      occurred_at = ~U[2026-03-01 10:00:00.000000Z]
      test_pid = self()

      set_mox_global()
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      Alethea.AI.EmbeddingsMock
      |> stub(:embed, fn
        ^query, [] ->
          send(test_pid, {:search_embedding_started, self()})

          receive do
            :release_search_embedding -> {:ok, query_vector}
          end

        other_query, [] ->
          Alethea.AI.Embeddings.Fake.embed(other_query, [])
      end)
      |> stub(:dimensions, fn -> 1024 end)
      |> stub(:model, fn -> "fake-embeddings-bge-m3" end)

      chunk =
        insert_rag_chunk!(
          professional,
          patient,
          "Refirió angustia intensa mientras hacía compras en el supermercado.",
          query_vector,
          "clinical_note",
          occurred_at
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      loading_html =
        view
        |> form("#evidence-search-form", %{"search" => %{"query" => query}})
        |> render_change()

      assert loading_html =~ "evidence-search-loading"
      assert_receive {:search_embedding_started, search_task_pid}
      send(search_task_pid, :release_search_embedding)

      render_async(view)

      card_selector = "#evidence-search-result-#{chunk.id}"
      assert has_element?(view, "#evidence-search-results-list #{card_selector}")

      assert element(view, "#{card_selector} .suggested-candidate-card__content") |> render() =~
               "angustia intensa"

      assert element(view, "#{card_selector} .badge--source-kind") |> render() =~ "Nota clínica"
      assert has_element?(view, "#{card_selector} .badge--affinity")

      assert element(view, "#{card_selector} .suggested-candidate-card__time") |> render() =~
               "01/03/2026 10:00"
    end

    test "renders a clean empty state when the query has no matches", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => "sin coincidencias"}})
      |> render_change()

      render_async(view)

      assert has_element?(view, "#evidence-search-empty")
      refute has_element?(view, "#evidence-search-results-list")
    end

    test "clear button restores the default suggested candidates view", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      query = "angustia en el supermercado"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])

      insert_rag_chunk!(
        professional,
        patient,
        "Angustia en el supermercado",
        query_vector,
        "patient_message",
        ~U[2026-03-01 10:00:00.000000Z]
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query}})
      |> render_change()

      render_async(view)
      assert has_element?(view, "#evidence-search-results-list")

      view |> element("#clear-evidence-search") |> render_click()

      assert has_element?(view, "#suggested-candidates-list")
      refute has_element?(view, "#evidence-search-results-list")
    end

    test "submitting an empty query restores the default suggested candidates view", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      query = "angustia en el supermercado"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])

      insert_rag_chunk!(
        professional,
        patient,
        "Angustia en el supermercado",
        query_vector,
        "patient_message",
        ~U[2026-03-01 10:00:00.000000Z]
      )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query}})
      |> render_change()

      render_async(view)
      assert has_element?(view, "#evidence-search-results-list")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => ""}})
      |> render_change()

      assert has_element?(view, "#suggested-candidates-list")
      refute has_element?(view, "#evidence-search-results-list")
    end
  end

  describe "evidence search source filter pills (#325)" do
    test "renders source filter pills with Todos active by default", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#evidence-search-bar #evidence-search-filters")

      assert has_element?(
               view,
               "#evidence-search-filter-all.filter-pill.filter-pill--active[aria-pressed='true']",
               "Todos"
             )

      assert has_element?(
               view,
               "#evidence-search-filter-telegram.filter-pill[aria-pressed='false']",
               "Telegram"
             )

      assert has_element?(
               view,
               "#evidence-search-filter-notes.filter-pill[aria-pressed='false']",
               "Notas"
             )

      assert has_element?(
               view,
               "#evidence-search-filter-sessions.filter-pill[aria-pressed='false']",
               "Sesiones"
             )
    end

    test "selecting a pill immediately filters search results to matching source kind and restoring Todos restores all",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      query = "ansiedad matutina"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])
      occurred_at = ~U[2026-03-01 10:00:00.000000Z]

      set_mox_global()
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      Alethea.AI.EmbeddingsMock
      |> stub(:embed, fn _query, [] -> {:ok, query_vector} end)
      |> stub(:dimensions, fn -> 1024 end)
      |> stub(:model, fn -> "fake-embeddings-bge-m3" end)

      note_chunk =
        insert_rag_chunk!(
          professional,
          patient,
          "Nota clínica sobre ansiedad matutina severa.",
          query_vector,
          "clinical_note",
          occurred_at
        )

      telegram_chunk =
        insert_rag_chunk!(
          professional,
          patient,
          "Mensaje de telegram reportando ansiedad al despertar.",
          query_vector,
          "patient_message",
          occurred_at
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query}})
      |> render_change()

      render_async(view)

      assert has_element?(view, "#evidence-search-result-#{note_chunk.id}")
      assert has_element?(view, "#evidence-search-result-#{telegram_chunk.id}")

      # Select Telegram pill -> immediately filters to telegram chunks
      view
      |> element("#evidence-search-filter-telegram")
      |> render_click()

      render_async(view)

      assert has_element?(
               view,
               "#evidence-search-filter-telegram.filter-pill--active[aria-pressed='true']"
             )

      assert has_element?(
               view,
               "#evidence-search-filter-all[aria-pressed='false']"
             )

      assert has_element?(view, "#evidence-search-result-#{telegram_chunk.id}")
      refute has_element?(view, "#evidence-search-result-#{note_chunk.id}")

      # Select Notas pill -> immediately filters to note chunks
      view
      |> element("#evidence-search-filter-notes")
      |> render_click()

      render_async(view)

      assert has_element?(
               view,
               "#evidence-search-filter-notes.filter-pill--active[aria-pressed='true']"
             )

      assert has_element?(view, "#evidence-search-result-#{note_chunk.id}")
      refute has_element?(view, "#evidence-search-result-#{telegram_chunk.id}")

      # Select Todos pill -> restores unconstrained results
      view
      |> element("#evidence-search-filter-all")
      |> render_click()

      render_async(view)

      assert has_element?(
               view,
               "#evidence-search-filter-all.filter-pill--active[aria-pressed='true']"
             )

      assert has_element?(view, "#evidence-search-result-#{note_chunk.id}")
      assert has_element?(view, "#evidence-search-result-#{telegram_chunk.id}")
    end

    test "filter state persists across keystrokes within the search session", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      initial_query = "ansiedad"
      next_query = "ansiedad matutina"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(initial_query, [])
      occurred_at = ~U[2026-03-01 10:00:00.000000Z]

      set_mox_global()
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

      on_exit(fn ->
        Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
          persistent: true
        )
      end)

      Alethea.AI.EmbeddingsMock
      |> stub(:embed, fn _query, [] -> {:ok, query_vector} end)
      |> stub(:dimensions, fn -> 1024 end)
      |> stub(:model, fn -> "fake-embeddings-bge-m3" end)

      note_chunk =
        insert_rag_chunk!(
          professional,
          patient,
          "Nota clínica sobre ansiedad",
          query_vector,
          "clinical_note",
          occurred_at
        )

      telegram_chunk =
        insert_rag_chunk!(
          professional,
          patient,
          "Mensaje de telegram sobre ansiedad",
          query_vector,
          "patient_message",
          occurred_at
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      # Select Telegram filter first
      view
      |> element("#evidence-search-filter-telegram")
      |> render_click()

      assert has_element?(
               view,
               "#evidence-search-filter-telegram.filter-pill--active[aria-pressed='true']"
             )

      # Type initial query
      view
      |> form("#evidence-search-form", %{"search" => %{"query" => initial_query}})
      |> render_change()

      render_async(view)

      assert has_element?(view, "#evidence-search-result-#{telegram_chunk.id}")
      refute has_element?(view, "#evidence-search-result-#{note_chunk.id}")

      # Type additional keystroke
      view
      |> form("#evidence-search-form", %{"search" => %{"query" => next_query}})
      |> render_change()

      render_async(view)

      # Filter remains active and persists across keystrokes
      assert has_element?(
               view,
               "#evidence-search-filter-telegram.filter-pill--active[aria-pressed='true']"
             )

      assert has_element?(view, "#evidence-search-result-#{telegram_chunk.id}")
      refute has_element?(view, "#evidence-search-result-#{note_chunk.id}")
    end
  end

  describe "direct citation from semantic search results (#326)" do
    test "each citable search result displays a [+ Citar] action", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      query = "angustia en el supermercado"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])
      occurred_at = ~U[2026-03-01 10:00:00.000000Z]

      chunk =
        insert_rag_chunk!(
          professional,
          patient,
          "Refirió angustia intensa en el supermercado",
          query_vector,
          "clinical_note",
          occurred_at
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query}})
      |> render_change()

      render_async(view)

      action_selector = "#cite-search-result-#{chunk.id}"
      assert has_element?(view, action_selector, "+ Citar")
    end

    test "cites search result directly into ConsultationEvidence, streams into timeline, and shows visual confirmation",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content = "Crisis de angustia al entrar al supermercado con taquicardia"
      query = "angustia supermercado"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])
      occurred_at = ~U[2026-03-01 11:00:00.000000Z]

      {:ok, note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, content)

      chunk =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          occurred_at,
          source_resource_id: note.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query}})
      |> render_change()

      render_async(view)

      action_selector = "#cite-search-result-#{chunk.id}"
      assert has_element?(view, action_selector, "+ Citar")

      render_click(view, "cite_search_result", %{
        "id" => chunk.id,
        "content" => "forged client plaintext"
      })

      # Creates ConsultationEvidence row with exact source reference
      evidence = Repo.one!(ConsultationEvidence)
      assert evidence.source_kind == "clinical_note"
      assert evidence.source_id == note.id
      assert evidence.encryption_version == 2
      refute evidence.encrypted_excerpt == content

      # Excerpt is encrypted under patient DEK with authoritative content
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, ^content} =
               PatientVault.decrypt(evidence.encrypted_excerpt, clinical_record_dek)

      # Timeline updates immediately
      assert has_element?(view, "#stat-evidence .stat-tile__value", "1")
      assert has_element?(view, ".review-item--evidence", content)

      # Search result card displays visual confirmation of being cited
      card_selector = "#evidence-search-result-#{chunk.id}"
      assert has_element?(view, "#{card_selector}.suggested-candidate-card--cited")
      assert has_element?(view, "#cited-confirmation-#{chunk.id}", "✓ Citado")
      refute has_element?(view, action_selector)
    end

    test "cites a patient message search result with message provenance and encrypted server content",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content = "Mensaje de paciente: no pude quedarme en la reunión"
      query = "reunión"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(query, [])
      occurred_at = ~U[2026-03-01 12:00:00.000000Z]

      source =
        insert_message_source!(
          patient,
          load_dek!(professional, patient),
          "inbound",
          content,
          occurred_at,
          "spontaneous"
        )

      chunk =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "patient_message",
          occurred_at,
          source_resource_id: source.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query}})
      |> render_change()

      render_async(view)

      action_selector = "#cite-search-result-#{chunk.id}"
      assert has_element?(view, action_selector, "+ Citar")

      render_click(view, "cite_search_result", %{
        "id" => chunk.id,
        "content" => "forged client plaintext"
      })

      evidence = Repo.one!(ConsultationEvidence)
      assert evidence.source_kind == "message"
      assert evidence.source_id == source.id
      refute evidence.encrypted_excerpt == content

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, ^content} =
               PatientVault.decrypt(evidence.encrypted_excerpt, clinical_record_dek)

      card_selector = "#evidence-search-result-#{chunk.id}"
      assert has_element?(view, "#{card_selector}.suggested-candidate-card--cited")
      assert has_element?(view, "#cited-confirmation-#{chunk.id}", "✓ Citado")
      refute has_element?(view, action_selector)
    end

    test "cited visual confirmation persists across subsequent searches within session", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      content1 = "Episodio 1: taquicardia severa"
      content2 = "Episodio 2: mareo repentino"
      query1 = "taquicardia"
      query2 = "episodio"

      {:ok, vector1} = Alethea.AI.Embeddings.Fake.embed(content1, [])
      {:ok, vector2} = Alethea.AI.Embeddings.Fake.embed(content2, [])

      {:ok, real_note1} =
        ClinicalRecord.create_clinical_note(professional, patient.id, content1)

      {:ok, real_note2} =
        ClinicalRecord.create_clinical_note(professional, patient.id, content2)

      note1 =
        insert_rag_chunk!(
          professional,
          patient,
          content1,
          vector1,
          "clinical_note",
          ~U[2026-03-01 10:00:00.000000Z],
          source_resource_id: real_note1.id
        )

      note2 =
        insert_rag_chunk!(
          professional,
          patient,
          content2,
          vector2,
          "clinical_note",
          ~U[2026-03-01 11:00:00.000000Z],
          source_resource_id: real_note2.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      # Search 1
      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query1}})
      |> render_change()

      render_async(view)

      assert has_element?(view, "#cite-search-result-#{note1.id}", "+ Citar")

      render_click(view, "cite_search_result", %{"id" => note1.id})

      assert has_element?(view, "#cited-confirmation-#{note1.id}", "✓ Citado")
      refute has_element?(view, "#cite-search-result-#{note1.id}")

      # Search 2
      view
      |> form("#evidence-search-form", %{"search" => %{"query" => query2}})
      |> render_change()

      render_async(view)

      # Note 1 remains marked as cited
      assert has_element?(view, "#cited-confirmation-#{note1.id}", "✓ Citado")
      refute has_element?(view, "#cite-search-result-#{note1.id}")

      # Note 2 is un-cited and shows action
      assert has_element?(view, "#cite-search-result-#{note2.id}", "+ Citar")
      refute has_element?(view, "#cited-confirmation-#{note2.id}")
    end

    test "rejects citation of forged or non-existent chunk id", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_click(view, "cite_search_result", %{"id" => Ecto.UUID.generate()})

      assert Repo.aggregate(ConsultationEvidence, :count) == 0
      assert render(view) =~ "No se pudo citar el resultado de búsqueda."
    end
  end

  describe "trim and cite exact text from suggestions (#327)" do
    test "each citable suggestion card features a secondary [Recortar] action alongside [+ Citar todo]",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content = "Crisis de angustia y taquicardia en lugares concurridos"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#cite-suggested-candidate-#{candidate.id}", "+ Citar todo")
      assert has_element?(view, "#trim-suggested-candidate-#{candidate.id}", "Recortar")
      assert has_element?(view, "#dismiss-suggested-candidate-#{candidate.id}", "Descartar ✕")
    end

    test "does not show [Recortar] action for uncitable suggestion source kinds", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      content = "Observación clínica no citable directamente"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinician_observation",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      assert has_element?(view, "#suggested-candidate-#{candidate.id}")
      refute has_element?(view, "#cite-suggested-candidate-#{candidate.id}")
      refute has_element?(view, "#trim-suggested-candidate-#{candidate.id}")
      assert has_element?(view, "#dismiss-suggested-candidate-#{candidate.id}")
    end

    test "clicking [Recortar] opens an inline excerpt editor populated with the chunk text", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      content = "Paciente manifiesta ataques de pánico recurrentes con mareos"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      refute has_element?(view, "#trim-candidate-form-#{candidate.id}")

      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      assert has_element?(view, "#trim-candidate-form-#{candidate.id}")
      assert has_element?(view, "#confirm-trim-candidate-#{candidate.id}", "Confirmar cita")
      assert has_element?(view, "#cancel-trim-candidate-#{candidate.id}", "Cancelar")

      input_element = element(view, "#trim-candidate-form-#{candidate.id} textarea")
      assert render(input_element) =~ content

      # Standard card actions are replaced while editing
      refute has_element?(view, "#cite-suggested-candidate-#{candidate.id}")
      refute has_element?(view, "#trim-suggested-candidate-#{candidate.id}")
    end

    test "canceling returns to the standard suggestion card view without side effects", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      content = "Paciente manifiesta ataques de pánico recurrentes con mareos"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      assert has_element?(view, "#trim-candidate-form-#{candidate.id}")

      view
      |> element("#cancel-trim-candidate-#{candidate.id}")
      |> render_click()

      refute has_element?(view, "#trim-candidate-form-#{candidate.id}")
      assert has_element?(view, "#cite-suggested-candidate-#{candidate.id}", "+ Citar todo")
      assert has_element?(view, "#trim-suggested-candidate-#{candidate.id}", "Recortar")

      assert has_element?(
               view,
               "#suggested-candidate-#{candidate.id} .suggested-candidate-card__content",
               content
             )

      assert Repo.aggregate(ConsultationEvidence, :count) == 0
    end

    test "confirming the trimmed excerpt creates a ConsultationEvidence with the selected excerpt only",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      full_content =
        "Paciente relata crisis de angustia y taquicardia al viajar en transporte público"

      trimmed_excerpt = "crisis de angustia y taquicardia"

      {:ok, real_note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, full_content)

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(full_content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          full_content,
          query_vector,
          "clinical_note",
          DateTime.utc_now(),
          source_resource_id: real_note.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      # Open trim editor
      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      # Submit form with trimmed excerpt
      view
      |> form("#trim-candidate-form-#{candidate.id}", %{
        "trim" => %{"excerpt" => trimmed_excerpt}
      })
      |> render_submit()

      evidence = Repo.one!(ConsultationEvidence)
      assert evidence.source_kind == "clinical_note"
      assert evidence.source_id == real_note.id
      assert evidence.encryption_version == 2
      refute evidence.encrypted_excerpt == full_content
      refute evidence.encrypted_excerpt == trimmed_excerpt

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, ^trimmed_excerpt} =
               PatientVault.decrypt(evidence.encrypted_excerpt, clinical_record_dek)

      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
      assert has_element?(view, "#stat-evidence .stat-tile__value", "1")
      assert has_element?(view, ".review-item--evidence", trimmed_excerpt)
      refute has_element?(view, ".review-item--evidence", full_content)
    end

    test "validates that trimmed excerpt is not empty and shows inline error", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      content = "Texto original de la sugerencia clínica"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      view
      |> form("#trim-candidate-form-#{candidate.id}", %{
        "trim" => %{"excerpt" => "   "}
      })
      |> render_submit()

      assert Repo.aggregate(ConsultationEvidence, :count) == 0
      assert has_element?(view, "#trim-candidate-form-#{candidate.id}")
      assert render(view) =~ "Ingresá el fragmento exacto que querés citar."
    end

    test "validates that trimmed excerpt must match the source content and displays error", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      full_content = "Texto original presente en la nota clínica"
      mismatched_excerpt = "Texto alterado que no existe en la nota"

      {:ok, real_note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, full_content)

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(full_content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          full_content,
          query_vector,
          "clinical_note",
          DateTime.utc_now(),
          source_resource_id: real_note.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      view
      |> form("#trim-candidate-form-#{candidate.id}", %{
        "trim" => %{"excerpt" => mismatched_excerpt}
      })
      |> render_submit()

      assert Repo.aggregate(ConsultationEvidence, :count) == 0
      assert has_element?(view, "#trim-candidate-form-#{candidate.id}")
      assert render(view) =~ "El fragmento debe coincidir exactamente con la fuente."
    end

    test "cites a trimmed patient message suggestion with message provenance", %{
      conn: conn,
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      full_content =
        "Mensaje del paciente: siento mucha ansiedad y falta de aire al salir de casa"

      trimmed_excerpt = "ansiedad y falta de aire"

      source =
        insert_message_source!(
          patient,
          load_dek!(professional, patient),
          "inbound",
          full_content,
          DateTime.utc_now(),
          "spontaneous"
        )

      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(full_content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          full_content,
          query_vector,
          "patient_message",
          DateTime.utc_now(),
          source_resource_id: source.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      view
      |> form("#trim-candidate-form-#{candidate.id}", %{
        "trim" => %{"excerpt" => trimmed_excerpt}
      })
      |> render_submit()

      evidence = Repo.one!(ConsultationEvidence)
      assert evidence.source_kind == "message"
      assert evidence.source_id == source.id
      refute evidence.encrypted_excerpt == full_content

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, ^trimmed_excerpt} =
               PatientVault.decrypt(evidence.encrypted_excerpt, clinical_record_dek)

      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
      assert has_element?(view, ".review-item--evidence", trimmed_excerpt)
    end

    test "dismissing a candidate while trimming it resets trimming state and removes candidate",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content = "Paciente reporta opresión en el pecho"
      {:ok, query_vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

      candidate =
        insert_rag_chunk!(
          professional,
          patient,
          content,
          query_vector,
          "clinical_note",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      view
      |> element("#trim-suggested-candidate-#{candidate.id}")
      |> render_click()

      assert has_element?(view, "#trim-candidate-form-#{candidate.id}")

      render_click(view, "dismiss_suggested_candidate", %{"id" => candidate.id})

      refute has_element?(view, "#suggested-candidate-#{candidate.id}")
      refute has_element?(view, "#trim-candidate-form-#{candidate.id}")
    end

    test "opening trim editor on another candidate switches the active trimming card and pre-populates its content",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      content1 = "Primer fragmento clínico relevante"
      content2 = "Segundo fragmento clínico diferente"

      {:ok, query_vector1} = Alethea.AI.Embeddings.Fake.embed(content1, [])
      {:ok, query_vector2} = Alethea.AI.Embeddings.Fake.embed(content2, [])

      candidate1 =
        insert_rag_chunk!(
          professional,
          patient,
          content1,
          query_vector1,
          "clinical_note",
          ~U[2026-03-01 10:00:00.000000Z]
        )

      candidate2 =
        insert_rag_chunk!(
          professional,
          patient,
          content2,
          query_vector2,
          "clinical_note",
          ~U[2026-03-01 11:00:00.000000Z]
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      # Open trim on candidate 1
      view
      |> element("#trim-suggested-candidate-#{candidate1.id}")
      |> render_click()

      assert has_element?(view, "#trim-candidate-form-#{candidate1.id}")
      assert render(element(view, "#trim-candidate-form-#{candidate1.id} textarea")) =~ content1

      # Candidate 2 is still in normal view
      refute has_element?(view, "#trim-candidate-form-#{candidate2.id}")
      assert has_element?(view, "#trim-suggested-candidate-#{candidate2.id}")

      # Now click trim on candidate 2
      view
      |> element("#trim-suggested-candidate-#{candidate2.id}")
      |> render_click()

      # Candidate 1 is back to normal view
      refute has_element?(view, "#trim-candidate-form-#{candidate1.id}")
      assert has_element?(view, "#trim-suggested-candidate-#{candidate1.id}")

      # Candidate 2 is now being trimmed with its own content
      assert has_element?(view, "#trim-candidate-form-#{candidate2.id}")
      assert render(element(view, "#trim-candidate-form-#{candidate2.id} textarea")) =~ content2
    end
  end

  describe "audio evidence citation (#328)" do
    test "shows a speaker badge and time marker on transcript cards and search results, but not on other kinds",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      transcript_content = "El paciente relata angustia al viajar en subterraneo"
      note_content = "Nota clinica sin marcadores de audio"

      transcript_candidate =
        insert_session_transcript_chunk!(
          professional,
          patient,
          transcript_content,
          "patient",
          860.0,
          910.0
        )

      {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, note_content)
      {:ok, note_vector} = Alethea.AI.Embeddings.Fake.embed(note_content, [])

      note_candidate =
        insert_rag_chunk!(
          professional,
          patient,
          note_content,
          note_vector,
          "clinical_note",
          DateTime.utc_now(),
          source_resource_id: note.id
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      render_async(view)

      transcript_card = "#suggested-candidate-#{transcript_candidate.id}"
      note_card = "#suggested-candidate-#{note_candidate.id}"

      assert has_element?(view, "#{transcript_card} .badge--speaker-patient", "Paciente")

      assert has_element?(
               view,
               "#{transcript_card} .suggested-candidate-card__audio",
               "min 14:20 – 15:10"
             )

      refute has_element?(view, "#{note_card} .badge--speaker")
      refute has_element?(view, "#{note_card} .suggested-candidate-card__audio")

      view
      |> form("#evidence-search-form", %{"search" => %{"query" => "angustia subterraneo"}})
      |> render_change()

      render_async(view)

      result_card = "#evidence-search-result-#{transcript_candidate.id}"
      assert has_element?(view, "#{result_card} .badge--speaker-patient", "Paciente")

      assert has_element?(
               view,
               "#{result_card} .suggested-candidate-card__audio",
               "min 14:20 – 15:10"
             )
    end

    test "citing a transcript chunk via any of the three citation paths persists the chunk's own markers, ignores forged client values, and shows them on the timeline (table-driven, R2-R5/R9)" do
      for cite_path <- [:cite_all, :trim, :search] do
        professional = create_professional!()
        patient = create_patient!(professional)
        target_behavior = create_target_behavior!(professional, patient)
        conn = log_in_professional(build_conn(), professional)

        content = "El terapeuta pregunta por la ultima crisis de panico"

        candidate =
          insert_session_transcript_chunk!(
            professional,
            patient,
            content,
            "therapist",
            860.0,
            910.0
          )

        {:ok, view, _html} =
          live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

        render_async(view)

        case cite_path do
          :cite_all ->
            assert has_element?(
                     view,
                     "#suggested-candidate-#{candidate.id} .badge--speaker-therapist"
                   )

            render_click(view, "cite_suggested_candidate", %{
              "id" => candidate.id,
              "speaker" => "patient",
              "audio_start_seconds" => "1.0",
              "audio_end_seconds" => "2.0"
            })

          :trim ->
            trimmed_excerpt = "ultima crisis de panico"

            view
            |> element("#trim-suggested-candidate-#{candidate.id}")
            |> render_click()

            view
            |> form("#trim-candidate-form-#{candidate.id}", %{
              "trim" => %{"excerpt" => trimmed_excerpt}
            })
            |> render_submit()

          :search ->
            view
            |> form("#evidence-search-form", %{"search" => %{"query" => "crisis de panico"}})
            |> render_change()

            render_async(view)

            assert has_element?(
                     view,
                     "#evidence-search-result-#{candidate.id} .badge--speaker-therapist"
                   )

            render_click(view, "cite_search_result", %{
              "id" => candidate.id,
              "speaker" => "patient",
              "audio_start_seconds" => "1.0",
              "audio_end_seconds" => "2.0"
            })
        end

        evidence =
          Repo.one!(
            from e in ConsultationEvidence, where: e.target_behavior_id == ^target_behavior.id
          )

        assert evidence.speaker == "therapist"
        assert evidence.audio_start_seconds == 860.0
        assert evidence.audio_end_seconds == 910.0

        assert has_element?(view, ".review-item--evidence .badge--speaker-therapist", "Terapeuta")

        assert has_element?(
                 view,
                 ".review-item--evidence .suggested-candidate-card__audio",
                 "min 14:20 – 15:10"
               )

        refute has_element?(view, ".review-item--evidence", "Fuente no disponible")
      end
    end
  end

  describe "new cited evidence marker since latest E-O-R-C version (#366)" do
    test "when no version has been registered, all live evidence is visible and unmarked as initial context",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      ev1 =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Primera evidencia inicial"
        )

      ev2 =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Segunda evidencia inicial"
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, ".review-item--evidence", "Primera evidencia inicial")
      assert has_element?(view, ".review-item--evidence", "Segunda evidencia inicial")
      refute has_element?(view, ".badge--new-evidence")
      refute has_element?(view, "#new-evidence-marker-#{ev1.id}")
      refute has_element?(view, "#new-evidence-marker-#{ev2.id}")
    end

    test "registers baseline with old citation, then citing a new one keeps old visible unmarked and marks new",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      old_evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Cita textual en la primera versión"
        )

      {:ok, _draft} =
        ClinicalRecord.upsert_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id,
          %{"response_motor" => "Conducta registrada en v1"}
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      # Register version 1 to capture the baseline containing old_evidence.
      view
      |> form("#functional-analysis-version-form", version: %{change_note: "Versión 1"})
      |> render_submit()

      assert has_element?(view, ".review-item--evidence", "Cita textual en la primera versión")
      refute has_element?(view, "#new-evidence-marker-#{old_evidence.id}")

      # Now insert a new citation absent from version 1 baseline.
      new_evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Nueva evidencia citada posteriormente"
        )

      # Re-mount Workbench to verify timeline loading with baseline.
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      # Old evidence remains visible and unmarked.
      assert has_element?(view, ".review-item--evidence", "Cita textual en la primera versión")
      refute has_element?(view, "#new-evidence-marker-#{old_evidence.id}")

      # New evidence is marked as new cited evidence with unique DOM ID.
      assert has_element?(view, ".review-item--evidence", "Nueva evidencia citada posteriormente")

      assert has_element?(
               view,
               "#new-evidence-marker-#{new_evidence.id}",
               "Nueva evidencia citada"
             )

      assert has_element?(view, ".badge--new-evidence")
    end

    test "latest-of-two registrations resets baseline so previously marked citation becomes unmarked",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      old_evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Cita inicial de v1"
        )

      {:ok, _draft} =
        ClinicalRecord.upsert_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id,
          %{"response_motor" => "Contenido v1"}
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#functional-analysis-version-form", version: %{change_note: "Versión 1"})
      |> render_submit()

      # Add second citation
      new_evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Cita agregada luego de v1"
        )

      # Re-mount view: new_evidence is marked
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#new-evidence-marker-#{new_evidence.id}")

      # Update draft and register version 2
      render_change(view, "change_functional_analysis", %{
        "functional_analysis" => %{"response_motor" => "Contenido v2 modificado"}
      })

      view
      |> form("#functional-analysis-version-form", version: %{change_note: "Versión 2"})
      |> render_submit()

      # After version 2 registration, baseline is reset to include both citations.
      # Both citations remain visible, and both are unmarked.
      assert has_element?(view, ".review-item--evidence", "Cita inicial de v1")
      assert has_element?(view, ".review-item--evidence", "Cita agregada luego de v1")
      refute has_element?(view, "#new-evidence-marker-#{old_evidence.id}")
      refute has_element?(view, "#new-evidence-marker-#{new_evidence.id}")
      refute has_element?(view, ".badge--new-evidence")
    end

    test "legal deletion removes the new citation marker and does not display deleted item as live",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      old_evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Cita permanente de v1"
        )

      {:ok, _draft} =
        ClinicalRecord.upsert_functional_analysis_content(
          professional,
          patient.id,
          target_behavior.id,
          %{"response_motor" => "Base v1"}
        )

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      view
      |> form("#functional-analysis-version-form", version: %{change_note: "Versión 1"})
      |> render_submit()

      new_evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Cita a ser eliminada legalmente"
        )

      # Verify it is marked before deletion
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#new-evidence-marker-#{new_evidence.id}")

      # Legally delete the new citation
      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"consultation_evidence", new_evidence.id},
                 actor: professional,
                 trigger: "manual"
               )

      # Re-mount Workbench
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      # Deleted evidence text is NOT visible in live evidence elements
      refute has_element?(view, ".review-item--evidence", "Cita a ser eliminada legalmente")
      refute has_element?(view, "#timeline-#{new_evidence.id}")

      # Marker is gone
      refute has_element?(view, "#new-evidence-marker-#{new_evidence.id}")
      refute has_element?(view, ".badge--new-evidence")

      # Old evidence is visible and unmarked
      assert has_element?(view, ".review-item--evidence", "Cita permanente de v1")
      refute has_element?(view, "#new-evidence-marker-#{old_evidence.id}")

      # Tombstone is rendered, but not as live evidence
      assert has_element?(view, ".review-item--tombstone")
      refute has_element?(view, ".review-item--evidence.review-item--tombstone")
    end

    test "cross-patient isolation: patient B's baseline is never leaked to patient A and authorization boundaries are enforced",
         %{
           conn: conn,
           professional: professional,
           patient: patient_a,
           target_behavior: target_behavior_a
         } do
      dek_a = load_dek!(professional, patient_a)

      _ev_a =
        insert_evidence!(
          professional,
          patient_a,
          target_behavior_a,
          dek_a,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Evidencia de Paciente A"
        )

      {:ok, _draft_a} =
        ClinicalRecord.upsert_functional_analysis_content(
          professional,
          patient_a.id,
          target_behavior_a.id,
          %{"response_motor" => "Draft A"}
        )

      {:ok, view_a, _html} =
        live(conn, ~p"/patients/#{patient_a.id}/target_behaviors/#{target_behavior_a.id}/review")

      view_a
      |> form("#functional-analysis-version-form", version: %{change_note: "Versión 1 de A"})
      |> render_submit()

      # Create patient B with own target behavior and evidence
      patient_b = create_patient!(professional)
      target_behavior_b = create_target_behavior!(professional, patient_b)
      dek_b = load_dek!(professional, patient_b)

      ev_b =
        insert_evidence!(
          professional,
          patient_b,
          target_behavior_b,
          dek_b,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Evidencia de Paciente B"
        )

      # Mount Patient B's workbench: no version registered, evidence is unmarked initial context
      {:ok, view_b, _html} =
        live(conn, ~p"/patients/#{patient_b.id}/target_behaviors/#{target_behavior_b.id}/review")

      assert has_element?(view_b, ".review-item--evidence", "Evidencia de Paciente B")
      refute has_element?(view_b, "#new-evidence-marker-#{ev_b.id}")
      refute has_element?(view_b, ".badge--new-evidence")

      # Boundary 1: mismatched patient and target behavior is denied with flash
      assert {:error, {:live_redirect, %{to: "/patients", flash: flash_mismatch}}} =
               live(
                 conn,
                 ~p"/patients/#{patient_a.id}/target_behaviors/#{target_behavior_b.id}/review"
               )

      assert flash_mismatch["error"] =~
               "La conducta objetivo no existe o no pertenece a este paciente."

      assert {:error, :not_found} =
               ClinicalRecord.list_functional_analysis_versions(
                 professional,
                 patient_a.id,
                 target_behavior_b.id
               )

      # Boundary 2: non-responsible professional is denied
      other_professional = create_professional!()
      other_conn = log_in_professional(build_conn(), other_professional)

      assert {:error, {:live_redirect, %{to: "/patients", flash: flash_unauthorized}}} =
               live(
                 other_conn,
                 ~p"/patients/#{patient_a.id}/target_behaviors/#{target_behavior_a.id}/review"
               )

      assert flash_unauthorized["error"] =~
               "No estás autorizado para ver esta línea de tiempo clínica."

      assert {:error, :unauthorized} =
               ClinicalRecord.list_functional_analysis_versions(
                 other_professional,
                 patient_a.id,
                 target_behavior_a.id
               )
    end

    test "legacy version with nil baseline treats all live evidence as unmarked initial context",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      ev =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Evidencia existente con versión legacy"
        )

      {:ok, draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Borrador legacy"
        )

      # Insert a legacy version with nil encrypted_cited_evidence_baseline
      {:ok, body_cipher} = PatientVault.encrypt("Borrador legacy", dek)
      {:ok, note_cipher} = PatientVault.encrypt("Versión sin baseline capturada", dek)

      %FunctionalAnalysisVersion{}
      |> FunctionalAnalysisVersion.changeset(%{
        draft_id: draft.id,
        patient_id: patient.id,
        professional_id: professional.id,
        target_behavior_id: target_behavior.id,
        version_number: 1,
        encryption_version: 1,
        encrypted_body: body_cipher,
        encrypted_change_note: note_cipher,
        encrypted_cited_evidence_baseline: nil
      })
      |> Repo.insert!()

      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(
               view,
               ".review-item--evidence",
               "Evidencia existente con versión legacy"
             )

      refute has_element?(view, "#new-evidence-marker-#{ev.id}")
      refute has_element?(view, ".badge--new-evidence")
    end

    test "fail-closed on version baseline decryption failure redirects to /patients",
         %{
           conn: conn,
           professional: professional,
           patient: patient,
           target_behavior: target_behavior
         } do
      dek = load_dek!(professional, patient)

      _ev =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          DateTime.utc_now(),
          "clinical_note",
          Ecto.UUID.generate(),
          "Evidencia antes del fallo de descifrado"
        )

      {:ok, draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Borrador para versión corrupta"
        )

      {:ok, body_cipher} = PatientVault.encrypt("Borrador", dek)
      {:ok, note_cipher} = PatientVault.encrypt("Nota", dek)

      # Insert version with corrupted ciphertext for baseline
      %FunctionalAnalysisVersion{}
      |> FunctionalAnalysisVersion.changeset(%{
        draft_id: draft.id,
        patient_id: patient.id,
        professional_id: professional.id,
        target_behavior_id: target_behavior.id,
        version_number: 1,
        encryption_version: 1,
        encrypted_body: body_cipher,
        encrypted_change_note: note_cipher,
        encrypted_cited_evidence_baseline: "corrupted_ciphertext_that_cannot_decrypt"
      })
      |> Repo.insert!()

      # Workbench must fail closed and redirect to /patients
      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(
                 conn,
                 ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review"
               )
    end
  end

  defp insert_session_transcript_chunk!(professional, patient, content, speaker, start, stop) do
    {:ok, transcript} =
      ClinicalRecord.create_session_transcript(professional, patient.id, %{
        spans: [%{start: start, end: stop, speaker: speaker, text: content}],
        recorded_at: DateTime.utc_now()
      })

    {:ok, vector} = Alethea.AI.Embeddings.Fake.embed(content, [])

    insert_rag_chunk!(
      professional,
      patient,
      content,
      vector,
      "session_transcript",
      DateTime.utc_now(),
      source_resource_id: transcript.id,
      speaker: speaker,
      audio_start_seconds: start,
      audio_end_seconds: stop
    )
  end

  defp generated_eorc_fields do
    {:ok, Map.new(eorc_fields(), &{&1, "IA: #{&1}"})}
  end

  defp eorc_fields do
    [
      "antecedents_distal",
      "antecedents_immediate",
      "organism_sleep",
      "organism_pain_or_discomfort",
      "organism_hunger_or_nutrition",
      "organism_learning_history",
      "response_physiological",
      "response_cognitive",
      "response_motor",
      "consequences_short_term",
      "consequences_long_term"
    ]
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

  defp insert_message_source!(patient, dek, direction, content, occurred_at, behavior_type) do
    {:ok, ciphertext} = PatientVault.encrypt(content, dek)

    %Journaling.Message{}
    |> Journaling.Message.changeset(%{
      direction: direction,
      behavior_type: behavior_type,
      encrypted_content: ciphertext,
      encryption_version: 1,
      timestamp: occurred_at,
      patient_id: patient.id
    })
    |> Repo.insert!()
  end

  defp insert_tombstone!(patient, target_behavior, deleted_at, resource_type) do
    %Tombstone{}
    |> Tombstone.changeset(%{
      resource_type: resource_type,
      resource_id: Ecto.UUID.generate(),
      patient_id: patient.id,
      target_behavior_id: target_behavior.id,
      deleted_at: deleted_at,
      trigger: "manual"
    })
    |> Repo.insert!()
  end

  defp insert_rag_chunk!(
         professional,
         patient,
         text,
         vector,
         resource_type,
         occurred_at,
         opts \\ []
       ) do
    resource_id = Keyword.get(opts, :source_resource_id, Ecto.UUID.generate())
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    attrs = [
      %{
        source_resource_type: resource_type,
        source_resource_id: resource_id,
        chunk_index: 0,
        encrypted_content: ciphertext,
        embedding: vector,
        embedding_model: "fake-embeddings-bge-m3",
        token_count: 10,
        full_event: true,
        source_occurred_at: occurred_at,
        patient_id: patient.id,
        professional_id: professional.id,
        speaker: Keyword.get(opts, :speaker),
        audio_start_seconds: Keyword.get(opts, :audio_start_seconds),
        audio_end_seconds: Keyword.get(opts, :audio_end_seconds)
      }
    ]

    {:ok, [chunk]} =
      Alethea.ClinicalRecord.Rag.Indexer.replace_chunks({resource_type, resource_id}, attrs)

    chunk
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
