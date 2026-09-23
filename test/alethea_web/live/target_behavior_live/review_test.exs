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
  import Mox
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    Retention,
    Tombstone
  }

  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias AletheaJobs.ClinicalRecordOutboxWorker

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

      assert has_element?(view, "#functional-analysis-form")
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
      end
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
         occurred_at
       ) do
    resource_id = Ecto.UUID.generate()
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
        professional_id: professional.id
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
