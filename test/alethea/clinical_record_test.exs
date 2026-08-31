defmodule Alethea.ClinicalRecordTest do
  @moduledoc """
  RED-phase specs for `Alethea.ClinicalRecord.create_target_behavior/3`
  (task 3.1) and `Alethea.ClinicalRecord.create_clinical_note/3`
  (task 4.1) (sdd/clinical-record-foundation, GitHub #194).

  `async: false`: the atomicity tests issue a raw `ALTER TABLE ...
  ADD CONSTRAINT` DDL statement, which takes a Postgres ACCESS
  EXCLUSIVE lock on the target table for the whole test — that would
  block any async test (in this file or elsewhere) concurrently
  reading/writing the same table (Judgment Day finding, 2026-08-30).
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    FunctionalAnalysisDraft,
    TargetBehavior
  }

  alias AletheaJobs.ClinicalRecordOutboxWorker

  @password "supersecret12"

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)

    %{professional: professional, patient: patient}
  end

  describe "create_target_behavior/3 — authorized" do
    test "persists the row and enqueues the outbox job", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, %TargetBehavior{} = target_behavior} =
               ClinicalRecord.create_target_behavior(professional, patient.id, "Salir a caminar")

      assert target_behavior.patient_id == patient.id
      assert target_behavior.professional_id == professional.id
      refute target_behavior.encrypted_description == "Salir a caminar"

      assert_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "writes exactly 2 NEW audit rows: KEK_LOAD then target_behavior_created success", %{
      professional: professional,
      patient: patient
    } do
      before_count =
        AuditLog |> where([a], a.professional_id == ^professional.id) |> Repo.aggregate(:count)

      assert {:ok, target_behavior} =
               ClinicalRecord.create_target_behavior(professional, patient.id, "Dormir 8 horas")

      new_rows =
        AuditLog
        |> where([a], a.professional_id == ^professional.id)
        |> order_by([a], asc: a.inserted_at)
        |> Repo.all()
        |> Enum.drop(before_count)

      assert length(new_rows) == 2
      assert Enum.any?(new_rows, &(&1.action == "KEK_LOAD"))

      created = Enum.find(new_rows, &(&1.action == "target_behavior_created"))
      assert created.resource_id == target_behavior.id
      assert created.resource_type == "target_behavior"
      assert created.details == %{"outcome" => "success"}
    end
  end

  describe "create_target_behavior/3 — unauthorized" do
    test "denies a professional not responsible for the patient: 0 rows, 0 jobs, 1 denied audit, no KEK/DEK load",
         %{patient: patient} do
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.create_target_behavior(
                 other_professional,
                 patient.id,
                 "No deberia persistir"
               )

      assert Repo.aggregate(TargetBehavior, :count) == 0
      refute_enqueued(worker: ClinicalRecordOutboxWorker)

      rows =
        AuditLog
        |> where([a], a.professional_id == ^other_professional.id)
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).action == "clinical_record_access_denied"
      assert hd(rows).details == %{"outcome" => "denied"}
    end
  end

  describe "create_target_behavior/3 — atomicity" do
    test "a failure past :record rolls back the whole Multi (no row, no audit, no job)", %{
      professional: professional,
      patient: patient
    } do
      # This is the only reachable failure branch of the pipeline's `case`.
      # With the current changesets, :audit and :outbox_event are built from
      # hardcoded, already-authorized values and declare no DB constraint
      # (see `Audit.changeset/1`, `Outbox.event/2`) — so they can never
      # return a normal `{:error, changeset}` via the public API. Forcing
      # that exact branch would need either a check_constraint that exists
      # only to be tripped by a test (dead code in prod) or reaching into
      # the private pipeline, breaking the "exactly 2 public functions"
      # design. Confirmed with the user (sdd/clinical-record-foundation,
      # task 3.1): document instead of fabricating dead code. This test
      # proves atomicity via the one failure mode actually reachable today —
      # a raw Postgres exception mid-transaction.
      Repo.query!(
        "ALTER TABLE target_behaviors ADD CONSTRAINT clinical_record_test_force_failure CHECK (encryption_version <> 1)"
      )

      assert_raise Ecto.ConstraintError, fn ->
        ClinicalRecord.create_target_behavior(professional, patient.id, "Nunca persiste")
      end

      assert Repo.aggregate(TargetBehavior, :count) == 0

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "target_behavior_created"
        )
        |> Repo.all()

      assert rows == []
      refute_enqueued(worker: ClinicalRecordOutboxWorker)
    end
  end

  describe "create_clinical_note/3 — authorized" do
    test "persists the row and enqueues the outbox job", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, %ClinicalNote{} = clinical_note} =
               ClinicalRecord.create_clinical_note(
                 professional,
                 patient.id,
                 "Paciente reporta mejora"
               )

      assert clinical_note.patient_id == patient.id
      assert clinical_note.professional_id == professional.id
      refute clinical_note.encrypted_body == "Paciente reporta mejora"

      assert_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "writes exactly 2 NEW audit rows: KEK_LOAD then clinical_note_created success", %{
      professional: professional,
      patient: patient
    } do
      before_count =
        AuditLog |> where([a], a.professional_id == ^professional.id) |> Repo.aggregate(:count)

      assert {:ok, clinical_note} =
               ClinicalRecord.create_clinical_note(professional, patient.id, "Sesion 12: avances")

      new_rows =
        AuditLog
        |> where([a], a.professional_id == ^professional.id)
        |> order_by([a], asc: a.inserted_at)
        |> Repo.all()
        |> Enum.drop(before_count)

      assert length(new_rows) == 2
      assert Enum.any?(new_rows, &(&1.action == "KEK_LOAD"))

      created = Enum.find(new_rows, &(&1.action == "clinical_note_created"))
      assert created.resource_id == clinical_note.id
      assert created.resource_type == "clinical_note"
      assert created.details == %{"outcome" => "success"}
    end
  end

  describe "create_clinical_note/3 — unauthorized" do
    test "denies a professional not responsible for the patient: 0 rows, 0 jobs, 1 denied audit, no KEK/DEK load",
         %{patient: patient} do
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.create_clinical_note(
                 other_professional,
                 patient.id,
                 "No deberia persistir"
               )

      assert Repo.aggregate(ClinicalNote, :count) == 0
      refute_enqueued(worker: ClinicalRecordOutboxWorker)

      rows =
        AuditLog
        |> where([a], a.professional_id == ^other_professional.id)
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).action == "clinical_record_access_denied"
      assert hd(rows).details == %{"outcome" => "denied"}
    end
  end

  describe "create_clinical_note/3 — atomicity" do
    test "a failure past :record rolls back the whole Multi (no row, no audit, no job)", %{
      professional: professional,
      patient: patient
    } do
      # Same reasoning as the target_behavior atomicity test above: :audit
      # and :outbox_event build from hardcoded, already-authorized values
      # with no DB constraint of their own, so the only reachable failure
      # mode via the public API is a raw Postgres exception mid-transaction.
      Repo.query!(
        "ALTER TABLE clinical_notes ADD CONSTRAINT clinical_record_test_force_failure_note CHECK (encryption_version <> 1)"
      )

      assert_raise Ecto.ConstraintError, fn ->
        ClinicalRecord.create_clinical_note(professional, patient.id, "Nunca persiste")
      end

      assert Repo.aggregate(ClinicalNote, :count) == 0

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "clinical_note_created"
        )
        |> Repo.all()

      assert rows == []
      refute_enqueued(worker: ClinicalRecordOutboxWorker)
    end
  end

  describe "cross-cutting acceptance checks (Phase 5)" do
    test "5.1 ciphertext opacity: raw SELECT on both tables returns binary, not the plaintext",
         %{professional: professional, patient: patient} do
      description = "Camina 30 minutos por dia"
      body = "Sesion 20: paciente estable"

      assert {:ok, target_behavior} =
               ClinicalRecord.create_target_behavior(professional, patient.id, description)

      assert {:ok, clinical_note} =
               ClinicalRecord.create_clinical_note(professional, patient.id, body)

      %{rows: [[tb_ciphertext]]} =
        Repo.query!(
          "SELECT encrypted_description FROM target_behaviors WHERE id = $1::text::uuid",
          [target_behavior.id]
        )

      %{rows: [[note_ciphertext]]} =
        Repo.query!(
          "SELECT encrypted_body FROM clinical_notes WHERE id = $1::text::uuid",
          [clinical_note.id]
        )

      assert is_binary(tb_ciphertext)
      refute tb_ciphertext == description
      refute String.contains?(tb_ciphertext, description)

      assert is_binary(note_ciphertext)
      refute note_ciphertext == body
      refute String.contains?(note_ciphertext, body)
    end

    test "5.2 trigger proof: raw UPDATE on clinical_notes raises via Postgrex, not Ecto",
         %{professional: professional, patient: patient} do
      assert {:ok, clinical_note} =
               ClinicalRecord.create_clinical_note(professional, patient.id, "Nota original")

      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE clinical_notes SET encryption_version = 2 WHERE id = $1::text::uuid",
                 [clinical_note.id]
               )
    end

    test "5.3 audit content-free: no description/body/alias in any audit row (success + denied)",
         %{professional: professional, patient: patient} do
      description = "Descripcion clinica sensible #{System.unique_integer([:positive])}"
      body = "Cuerpo de nota clinica sensible #{System.unique_integer([:positive])}"
      other_professional = create_professional!()

      assert {:ok, _} =
               ClinicalRecord.create_target_behavior(professional, patient.id, description)

      assert {:ok, _} = ClinicalRecord.create_clinical_note(professional, patient.id, body)

      assert {:error, :unauthorized} =
               ClinicalRecord.create_target_behavior(
                 other_professional,
                 patient.id,
                 "irrelevante"
               )

      # Scoped to ClinicalRecord's own action vocabulary — `audit_logs` is
      # the shared table, and setup's own `create_patient!/1` writes an
      # unrelated CREATE_PATIENT row that legitimately carries `alias` in
      # its (unconstrained) `Accounts.log_action/1` details; that row is
      # not something `Alethea.ClinicalRecord.Audit` produced.
      rows =
        AuditLog
        |> where([a], a.professional_id in ^[professional.id, other_professional.id])
        |> where(
          [a],
          a.action in ^~w(KEK_LOAD target_behavior_created clinical_note_created clinical_record_access_denied)
        )
        |> Repo.all()

      assert rows != []

      # Patient here carries no plaintext phone field (that lives only on
      # the Foundation identity schema, out of scope for ClinicalRecord) —
      # `alias` is the one plaintext PII field this layer actually has, so
      # it stands in for the "phone" check the task lists.
      Enum.each(rows, fn row ->
        haystack = "#{inspect(row.details)} #{row.action} #{row.resource_type}"
        refute haystack =~ description
        refute haystack =~ body
        refute haystack =~ patient.alias
      end)
    end

    test "5.4 outbox content-free: enqueued args carry only identifier keys, no PII",
         %{professional: professional, patient: patient} do
      description = "Otra conducta con texto sensible"
      body = "Otra nota con texto sensible"

      assert {:ok, target_behavior} =
               ClinicalRecord.create_target_behavior(professional, patient.id, description)

      assert {:ok, clinical_note} =
               ClinicalRecord.create_clinical_note(professional, patient.id, body)

      jobs = all_enqueued(worker: ClinicalRecordOutboxWorker)
      assert length(jobs) == 2

      Enum.each(jobs, fn job ->
        assert Enum.sort(Map.keys(job.args)) ==
                 Enum.sort([
                   "event",
                   "resource_type",
                   "resource_id",
                   "patient_id",
                   "professional_id"
                 ])
      end)

      tb_job = Enum.find(jobs, &(&1.args["resource_type"] == "target_behavior"))
      note_job = Enum.find(jobs, &(&1.args["resource_type"] == "clinical_note"))

      assert tb_job.args["resource_id"] == target_behavior.id
      assert note_job.args["resource_id"] == clinical_note.id
    end

    test "5.5 journaling separation: messages/summaries counts for the patient are unchanged",
         %{professional: professional, patient: patient} do
      message_count_before =
        Journaling.Message |> where(patient_id: ^patient.id) |> Repo.aggregate(:count)

      summary_count_before =
        Journaling.Summary |> where(patient_id: ^patient.id) |> Repo.aggregate(:count)

      assert {:ok, _} =
               ClinicalRecord.create_target_behavior(
                 professional,
                 patient.id,
                 "Conducta objetivo"
               )

      assert {:ok, _} =
               ClinicalRecord.create_clinical_note(professional, patient.id, "Nota clinica")

      assert Journaling.Message |> where(patient_id: ^patient.id) |> Repo.aggregate(:count) ==
               message_count_before

      assert Journaling.Summary |> where(patient_id: ^patient.id) |> Repo.aggregate(:count) ==
               summary_count_before
    end
  end

  describe "add_consultation_evidence/4 — authorized" do
    test "persists the row scoped to the target behavior and enqueues the outbox job", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      occurred_at = DateTime.utc_now()

      assert {:ok, %ConsultationEvidence{} = evidence} =
               ClinicalRecord.add_consultation_evidence(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "clinical_note",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "Paciente menciona insomnio",
                   occurred_at: occurred_at
                 }
               )

      assert evidence.patient_id == patient.id
      assert evidence.target_behavior_id == target_behavior.id
      refute evidence.encrypted_excerpt == "Paciente menciona insomnio"

      assert_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "writes exactly 1 NEW audit row: consultation_evidence_created success", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      before_count =
        AuditLog |> where([a], a.professional_id == ^professional.id) |> Repo.aggregate(:count)

      assert {:ok, evidence} =
               ClinicalRecord.add_consultation_evidence(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "message",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "Mensaje citado",
                   occurred_at: DateTime.utc_now()
                 }
               )

      new_rows =
        AuditLog
        |> where([a], a.professional_id == ^professional.id)
        |> Repo.all()
        |> Enum.drop(before_count)

      assert length(new_rows) == 2
      assert Enum.any?(new_rows, &(&1.action == "KEK_LOAD"))

      created = Enum.find(new_rows, &(&1.action == "consultation_evidence_created"))
      assert created.resource_id == evidence.id
    end
  end

  describe "add_consultation_evidence/4 — unauthorized" do
    test "denies a professional not responsible for the patient: 0 rows, 0 jobs, 1 denied audit",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.add_consultation_evidence(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "message",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "No deberia persistir",
                   occurred_at: DateTime.utc_now()
                 }
               )

      assert Repo.aggregate(ConsultationEvidence, :count) == 0

      refute_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{"event" => "consultation_evidence_created"}
      )

      rows =
        AuditLog |> where([a], a.professional_id == ^other_professional.id) |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).action == "clinical_record_access_denied"
    end
  end

  describe "add_clinician_observation/4" do
    test "authorized: persists the row with no source columns and enqueues the outbox job", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, %ClinicianObservation{} = observation} =
               ClinicalRecord.add_clinician_observation(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "Observacion directa del clinico"
               )

      assert observation.patient_id == patient.id
      assert observation.target_behavior_id == target_behavior.id
      refute observation.encrypted_body == "Observacion directa del clinico"

      assert_enqueued(worker: ClinicalRecordOutboxWorker)

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "clinician_observation_created"
        )
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).resource_id == observation.id
    end

    test "unauthorized: denies a professional not responsible for the patient", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.add_clinician_observation(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 "No deberia persistir"
               )

      assert Repo.aggregate(ClinicianObservation, :count) == 0

      refute_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{"event" => "clinician_observation_created"}
      )
    end
  end

  describe "update_clinician_observation/4" do
    test "authorized: re-encrypts the body, keeps ownership fields, enqueues the outbox job", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, observation} =
        ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Cuerpo original"
        )

      assert {:ok, %ClinicianObservation{} = updated} =
               ClinicalRecord.update_clinician_observation(
                 professional,
                 patient.id,
                 observation.id,
                 "Cuerpo editado"
               )

      assert updated.id == observation.id
      refute updated.encrypted_body == observation.encrypted_body

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "clinician_observation_updated"
        )
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).resource_id == observation.id

      jobs = all_enqueued(worker: ClinicalRecordOutboxWorker)
      assert Enum.any?(jobs, &(&1.args["event"] == "clinician_observation_updated"))
    end

    test "unauthorized: denies a professional not responsible for the patient", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, observation} =
        ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Cuerpo original"
        )

      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.update_clinician_observation(
                 other_professional,
                 patient.id,
                 observation.id,
                 "No deberia persistir"
               )

      reloaded = Repo.get!(ClinicianObservation, observation.id)
      assert reloaded.encrypted_body == observation.encrypted_body
    end

    test "cross-patient id guess fails: an observation id from another patient is not found", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, observation} =
        ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Cuerpo original"
        )

      other_professional = create_professional!()
      other_patient = create_patient!(other_professional)

      assert {:error, :not_found} =
               ClinicalRecord.update_clinician_observation(
                 other_professional,
                 other_patient.id,
                 observation.id,
                 "Intento de secuestro"
               )

      reloaded = Repo.get!(ClinicianObservation, observation.id)
      assert reloaded.encrypted_body == observation.encrypted_body
    end
  end

  describe "request_ai_proposals/3" do
    test "authorized: enqueues the AI proposal worker with identifier-only args", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, :requested} =
               ClinicalRecord.request_ai_proposals(professional, patient.id, target_behavior.id)

      jobs = all_enqueued(worker: "AletheaJobs.AIProposalWorker")
      assert length(jobs) == 1
      job = hd(jobs)

      assert job.queue == "ai_analysis"
      assert job.args["professional_id"] == professional.id
      assert job.args["patient_id"] == patient.id
      assert job.args["target_behavior_id"] == target_behavior.id

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "ai_proposals_requested"
        )
        |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).resource_id == target_behavior.id
    end

    test "unauthorized: denies a professional not responsible for the patient, no job enqueued",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.request_ai_proposals(
                 other_professional,
                 patient.id,
                 target_behavior.id
               )

      assert all_enqueued(worker: "AletheaJobs.AIProposalWorker") == []

      rows =
        AuditLog |> where([a], a.professional_id == ^other_professional.id) |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).action == "clinical_record_access_denied"
    end
  end

  describe "AIProposal lifecycle — accept_ai_proposal/3, edit_ai_proposal/4, discard_ai_proposal/3" do
    test "accept_ai_proposal/3 authorized: status becomes accepted, text preserved", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      assert {:ok, %AIProposal{} = accepted} =
               ClinicalRecord.accept_ai_proposal(professional, patient.id, proposal.id)

      assert accepted.id == proposal.id
      assert accepted.status == "accepted"
      assert accepted.encrypted_original_text == proposal.encrypted_original_text
      assert accepted.encrypted_text == proposal.encrypted_text

      assert_enqueued(worker: ClinicalRecordOutboxWorker)

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "ai_proposal_accepted"
        )
        |> Repo.all()

      assert length(rows) == 1
    end

    test "accept_ai_proposal/3 unauthorized: denies, proposal unchanged", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.accept_ai_proposal(other_professional, patient.id, proposal.id)

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "pending"
    end

    test "accept_ai_proposal/3 cross-patient id guess fails", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      other_professional = create_professional!()
      other_patient = create_patient!(other_professional)

      assert {:error, :not_found} =
               ClinicalRecord.accept_ai_proposal(
                 other_professional,
                 other_patient.id,
                 proposal.id
               )

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "pending"
    end

    test "edit_ai_proposal/4 authorized: encrypted_text changes, encrypted_original_text is write-once",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      assert {:ok, %AIProposal{} = edited} =
               ClinicalRecord.edit_ai_proposal(
                 professional,
                 patient.id,
                 proposal.id,
                 "Texto editado por el clinico"
               )

      assert edited.status == "edited"
      assert edited.encrypted_original_text == proposal.encrypted_original_text
      refute edited.encrypted_text == proposal.encrypted_text

      rows =
        AuditLog
        |> where([a], a.professional_id == ^professional.id and a.action == "ai_proposal_edited")
        |> Repo.all()

      assert length(rows) == 1
    end

    test "discard_ai_proposal/3 authorized: status becomes discarded, row is kept", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      before_count = Repo.aggregate(AIProposal, :count)

      assert {:ok, %AIProposal{} = discarded} =
               ClinicalRecord.discard_ai_proposal(professional, patient.id, proposal.id)

      assert discarded.status == "discarded"
      assert Repo.aggregate(AIProposal, :count) == before_count

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "ai_proposal_discarded"
        )
        |> Repo.all()

      assert length(rows) == 1
    end
  end

  describe "upsert_functional_analysis_draft/4" do
    test "authorized: first call inserts, second call replaces the same row", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, %FunctionalAnalysisDraft{} = draft} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "Borrador inicial"
               )

      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 1

      assert {:ok, %FunctionalAnalysisDraft{} = updated_draft} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "Borrador actualizado"
               )

      assert updated_draft.id == draft.id
      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 1
      refute updated_draft.encrypted_body == draft.encrypted_body

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and
            a.action == "functional_analysis_draft_saved"
        )
        |> Repo.all()

      assert length(rows) == 2

      assert_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "unauthorized: denies a professional not responsible for the patient", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 "No deberia persistir"
               )

      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 0
    end
  end

  describe "review_timeline/3" do
    test "authorized: merges evidence/observation/proposal chronologically with decrypted text",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      t1 = ~U[2026-01-01 10:00:00.000000Z]
      t2 = ~U[2026-01-01 11:00:00.000000Z]
      t3 = ~U[2026-01-01 12:00:00.000000Z]

      proposal =
        insert_proposal!(professional, patient, target_behavior, dek, t1, "Patron sugerido")

      evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          t2,
          "clinical_note",
          Ecto.UUID.generate(),
          "Cita textual del profesional"
        )

      observation =
        insert_observation!(
          professional,
          patient,
          target_behavior,
          dek,
          t3,
          "Observacion directa"
        )

      assert {:ok, timeline} =
               ClinicalRecord.review_timeline(professional, patient.id, target_behavior.id)

      assert [proposal_item, evidence_item, observation_item] = timeline

      assert proposal_item.id == proposal.id
      assert proposal_item.kind == :ai_proposal
      assert proposal_item.occurred_at == t1
      assert proposal_item.text == "Patron sugerido"
      assert proposal_item.status == "pending"

      assert evidence_item.id == evidence.id
      assert evidence_item.kind == :consultation_evidence
      assert evidence_item.occurred_at == t2
      assert evidence_item.text == "Cita textual del profesional"

      assert observation_item.id == observation.id
      assert observation_item.kind == :clinician_observation
      assert observation_item.occurred_at == t3
      assert observation_item.text == "Observacion directa"
    end

    test "equal occurred_at ties break deterministically by kind_rank (evidence, observation, proposal)",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      tied_at = ~U[2026-02-01 09:00:00.000000Z]

      observation =
        insert_observation!(professional, patient, target_behavior, dek, tied_at, "Obs empatada")

      proposal =
        insert_proposal!(professional, patient, target_behavior, dek, tied_at, "IA empatada")

      evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          tied_at,
          "clinical_note",
          Ecto.UUID.generate(),
          "Evidencia empatada"
        )

      assert {:ok, timeline} =
               ClinicalRecord.review_timeline(professional, patient.id, target_behavior.id)

      assert [item_1, item_2, item_3] = timeline
      assert {item_1.kind, item_1.id} == {:consultation_evidence, evidence.id}
      assert {item_2.kind, item_2.id} == {:clinician_observation, observation.id}
      assert {item_3.kind, item_3.id} == {:ai_proposal, proposal.id}
    end

    test "unauthorized: denies a professional not responsible for the patient", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.review_timeline(other_professional, patient.id, target_behavior.id)
    end

    test "discarded proposals are still returned (design D5: observable, not filtered)", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      assert {:ok, %AIProposal{status: "discarded"}} =
               ClinicalRecord.discard_ai_proposal(professional, patient.id, proposal.id)

      assert {:ok, timeline} =
               ClinicalRecord.review_timeline(professional, patient.id, target_behavior.id)

      assert [%{kind: :ai_proposal, id: proposal_id, status: "discarded"}] = timeline
      assert proposal_id == proposal.id
    end

    test "a cited source deleted after citation still renders from the stored excerpt, source: :unavailable",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      {:ok, message} =
        Journaling.save_message(patient, "Mensaje que sera borrado", dek, "inbound", "elicited")

      evidence =
        insert_evidence!(
          professional,
          patient,
          target_behavior,
          dek,
          ~U[2026-03-01 08:00:00.000000Z],
          "message",
          message.id,
          "Excerpt copiado al citar"
        )

      Repo.delete!(message)

      assert {:ok, timeline} =
               ClinicalRecord.review_timeline(professional, patient.id, target_behavior.id)

      assert [item] = timeline
      assert item.id == evidence.id
      assert item.kind == :consultation_evidence
      assert item.text == "Excerpt copiado al citar"
      assert item.source == :unavailable
    end
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
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt(excerpt, dek)

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
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt(body, dek)

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
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt(text, dek)

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

  defp create_ai_proposal!(professional, patient, target_behavior) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt("Patron sugerido por IA", dek)

    %AIProposal{}
    |> AIProposal.changeset(%{
      encrypted_original_text: ciphertext,
      encrypted_text: ciphertext,
      model_version: "phi4-mini-test",
      occurred_at: DateTime.utc_now(),
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id
    })
    |> Repo.insert!()
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "clinical-record-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Target Behavior"
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
end
