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
      assert has_element?(view, "form#draft-form")
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

      assert render(view) =~ "Propuesta aceptada y agregada al borrador."

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

    test "no longer offers duplicated clinical note form", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      refute has_element?(view, "#note-form")
    end

    test "draft textarea exposes guided clinical placeholder", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#draft-form textarea[placeholder*='Antecedentes']")
      assert has_element?(view, "#draft-form textarea[placeholder*='Función hipotetizada']")
    end

    test "loading the clinical structure populates the draft form", %{
      conn: conn,
      patient: patient,
      target_behavior: target_behavior
    } do
      {:ok, view, _html} =
        live(conn, ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert has_element?(view, "#insert-draft-structure-button")

      view
      |> element("#insert-draft-structure-button")
      |> render_click()

      rendered = render(view)
      assert rendered =~ "Antecedentes:"
      assert rendered =~ "Función hipotetizada:"
      assert rendered =~ "Evidencia pendiente / dudas:"

      refute has_element?(view, "#insert-draft-structure-button")
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
      assert has_element?(view, "#draft-form")
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
      assert has_element?(view, "#draft-form")
    end

    test "opening lists patient sources in domain order with provenance, then selection shows full content",
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
      assert has_element?(view, "#evidence-source-#{inbound.id}", "Mensaje entrante")
      assert has_element?(view, "#evidence-source-#{inbound.id}", "espontáneo")
      assert has_element?(view, "#evidence-source-#{outbound.id}", "Mensaje saliente")
      assert has_element?(view, "#evidence-source-#{outbound.id}", "provocado")
      assert has_element?(view, "#evidence-source-#{note.id}", "Nota clínica")

      assert {:ok, domain_sources} =
               ClinicalRecord.list_evidence_sources(professional, patient.id)

      rendered_positions =
        Enum.map(domain_sources, fn source ->
          :binary.match(html, source.id) |> elem(0)
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
               "Sin borrador de análisis funcional"
             )

      assert has_element?(view, "#draft-form")
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
      assert has_element?(view, "#empty-observations")
      assert has_element?(view, "#empty-draft")

      # Adding an observation removes the observations empty state
      view
      |> form("#observation-form", %{"observation" => %{"body" => "Nueva observacion"}})
      |> render_submit()

      refute has_element?(view, "#empty-observations")
      assert has_element?(view, "#stat-observations .stat-tile__value", "1")

      # Saving draft removes the draft empty state
      view
      |> form("#draft-form", %{"draft" => %{"body" => "Borrador de prueba"}})
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

    test "accepting a proposal adds to draft and displays specific info flash", %{
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

      assert html =~ "Propuesta aceptada y agregada al borrador."
    end

    test "accepting a proposal when draft is legally deleted warns clinician", %{
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

      assert html =~ "Propuesta aceptada, pero no pudo agregarse al borrador."
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
