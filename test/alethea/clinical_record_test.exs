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
  import Mox

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.Rag.{Chunk, Indexer}

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    DismissedEvidenceSuggestion,
    FunctionalAnalysisContent,
    FunctionalAnalysisDraft,
    TargetBehavior,
    Tombstone
  }

  alias AletheaJobs.ClinicalRecordOutboxWorker

  @password "supersecret12"

  setup :verify_on_exit!

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

  describe "list_clinical_notes/2" do
    test "lists decrypted notes for an authorized patient in reverse chronological order with preloaded professional",
         %{professional: professional, patient: patient} do
      assert {:ok, []} = ClinicalRecord.list_clinical_notes(professional, patient.id)

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt("Primera nota", dek)

      past_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      _note1 =
        %ClinicalNote{inserted_at: past_time}
        |> ClinicalNote.changeset(%{
          patient_id: patient.id,
          professional_id: professional.id,
          encrypted_body: ciphertext
        })
        |> Repo.insert!()

      assert {:ok, note2} =
               ClinicalRecord.create_clinical_note(
                 professional,
                 patient.id,
                 "Segunda nota más reciente"
               )

      assert {:ok, [latest, older]} =
               ClinicalRecord.list_clinical_notes(professional, patient.id)

      assert latest.id == note2.id
      assert latest.body == "Segunda nota más reciente"
      assert latest.professional.id == professional.id
      assert latest.professional.full_name == professional.full_name

      assert older.body == "Primera nota"
      assert older.professional.id == professional.id
    end

    test "denies unauthorized professional and logs denial audit", %{
      professional: professional,
      patient: patient
    } do
      other_professional = create_professional!()

      {:ok, _note} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Nota confidencial")

      assert {:error, :unauthorized} =
               ClinicalRecord.list_clinical_notes(other_professional, patient.id)

      audit_rows =
        AuditLog
        |> where([a], a.professional_id == ^other_professional.id)
        |> Repo.all()

      assert length(audit_rows) == 1
      assert hd(audit_rows).action == "clinical_record_access_denied"
      assert hd(audit_rows).details == %{"outcome" => "denied"}
    end
  end

  describe "list_target_behaviors/2" do
    test "returns only the authorized patient's decrypted behaviors with derived draft status in deterministic order",
         %{professional: professional, patient: patient} do
      other_patient = create_patient!(professional)

      assert {:ok, _other_target} =
               ClinicalRecord.create_target_behavior(
                 professional,
                 other_patient.id,
                 "Conducta de otro paciente"
               )

      assert {:ok, oldest} =
               ClinicalRecord.create_target_behavior(
                 professional,
                 patient.id,
                 "Conducta sin borrador"
               )

      assert {:ok, saved} =
               ClinicalRecord.create_target_behavior(
                 professional,
                 patient.id,
                 "Conducta con borrador"
               )

      assert {:ok, tombstoned} =
               ClinicalRecord.create_target_behavior(
                 professional,
                 patient.id,
                 "Conducta con borrador eliminado"
               )

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 saved.id,
                 "Contenido que no debe salir en el listado"
               )

      deleted_draft =
        %FunctionalAnalysisDraft{}
        |> FunctionalAnalysisDraft.changeset(%{
          encrypted_body: <<1, 2, 3>>,
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: tombstoned.id
        })
        |> Repo.insert!()

      Repo.delete!(deleted_draft)

      %Tombstone{}
      |> Tombstone.changeset(%{
        resource_type: "functional_analysis_draft",
        resource_id: deleted_draft.id,
        target_behavior_id: tombstoned.id,
        patient_id: patient.id,
        deleted_at: ~U[2026-09-16 12:00:00Z],
        deleted_by_id: professional.id,
        trigger: "manual"
      })
      |> Repo.insert!()

      assert {:ok, behaviors} =
               ClinicalRecord.list_target_behaviors(professional, patient.id)

      assert Enum.map(behaviors, & &1.id) ==
               [oldest, saved, tombstoned]
               |> Enum.sort_by(&{&1.inserted_at, &1.id}, :desc)
               |> Enum.map(& &1.id)

      by_id = Map.new(behaviors, &{&1.id, &1})

      assert by_id[oldest.id] == %{
               id: oldest.id,
               description: "Conducta sin borrador",
               functional_analysis_status: :not_started
             }

      assert by_id[saved.id] == %{
               id: saved.id,
               description: "Conducta con borrador",
               functional_analysis_status: :saved
             }

      assert by_id[tombstoned.id] == %{
               id: tombstoned.id,
               description: "Conducta con borrador eliminado",
               functional_analysis_status: :legally_deleted
             }
    end

    test "returns an empty list when the authorized patient has no target behaviors", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, []} = ClinicalRecord.list_target_behaviors(professional, patient.id)
    end

    test "denies a professional who is not responsible for the patient", %{patient: patient} do
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.list_target_behaviors(other_professional, patient.id)

      assert [audit] =
               AuditLog
               |> where([a], a.professional_id == ^other_professional.id)
               |> Repo.all()

      assert audit.action == "clinical_record_access_denied"
      assert audit.details == %{"outcome" => "denied"}
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

  describe "trusted evidence sources" do
    test "lists only the authorized patient's decrypted notes and messages with inbound messages first",
         %{professional: professional, patient: patient} do
      other_patient = create_patient!(professional)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      note =
        insert_clinical_note_source!(
          professional,
          patient,
          clinical_record_dek,
          2,
          "Complete clinical note",
          ~U[2026-09-16 10:00:00Z]
        )

      inbound =
        insert_message_source!(
          patient,
          patient_dek,
          "inbound",
          "Patient's complete inbound message",
          ~U[2026-09-16 09:00:00Z]
        )

      outbound =
        insert_message_source!(
          patient,
          patient_dek,
          "outbound",
          "Clinician's newer outbound message",
          ~U[2026-09-16 11:00:00Z]
        )

      _foreign =
        insert_message_source!(
          other_patient,
          patient_dek_for!(professional, other_patient),
          "inbound",
          "Foreign patient content",
          ~U[2026-09-16 12:00:00Z]
        )

      assert {:ok, sources} = ClinicalRecord.list_evidence_sources(professional, patient.id)
      assert Enum.map(sources, & &1.id) == [inbound.id, outbound.id, note.id]

      assert [inbound_source, outbound_source, note_source] = sources
      assert inbound_source.kind == :message
      assert inbound_source.content == "Patient's complete inbound message"
      assert inbound_source.direction == "inbound"
      assert inbound_source.behavior_type == "spontaneous"
      assert inbound_source.occurred_at == ~U[2026-09-16 09:00:00Z]

      assert outbound_source.direction == "outbound"
      assert outbound_source.content == "Clinician's newer outbound message"

      assert note_source.kind == :clinical_note
      assert note_source.content == "Complete clinical note"
      assert note_source.direction == nil
      assert note_source.professional_id == professional.id
      assert note_source.occurred_at == ~U[2026-09-16 10:00:00Z]
    end

    test "listing denies an unauthorized professional", %{patient: patient} do
      assert {:error, :unauthorized} =
               ClinicalRecord.list_evidence_sources(create_professional!(), patient.id)
    end

    test "cites an authoritative exact excerpt and derives source time with encryption, audit, and outbox",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)

      source =
        insert_message_source!(
          patient,
          patient_dek,
          "inbound",
          "I slept poorly for three nights.",
          ~U[2026-09-15 08:30:00Z]
        )

      assert {:ok, %ConsultationEvidence{} = evidence} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{source_kind: "message", source_id: source.id, excerpt: "slept poorly"}
               )

      assert evidence.source_kind == "message"
      assert evidence.source_id == source.id
      assert DateTime.compare(evidence.occurred_at, source.timestamp) == :eq
      refute evidence.encrypted_excerpt == "slept poorly"

      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, "slept poorly"} =
               Alethea.Encryption.PatientVault.decrypt(
                 evidence.encrypted_excerpt,
                 clinical_record_dek
               )

      assert %AuditLog{resource_id: evidence_id, details: %{"outcome" => "success"}} =
               Repo.get_by!(AuditLog,
                 professional_id: professional.id,
                 action: "consultation_evidence_created",
                 resource_type: "consultation_evidence"
               )

      assert evidence_id == evidence.id

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{"event" => "consultation_evidence_created"}
      )
    end

    test "cites a clinical note using its timestamp and encrypted storage", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      source =
        insert_clinical_note_source!(
          professional,
          patient,
          clinical_record_dek,
          2,
          "Patient reports restful sleep.",
          ~U[2026-09-17 14:45:00Z]
        )

      assert {:ok, %ConsultationEvidence{} = evidence} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "clinical_note",
                   source_id: source.id,
                   excerpt: "restful sleep"
                 }
               )

      assert evidence.source_kind == "clinical_note"
      assert evidence.source_id == source.id
      assert DateTime.compare(evidence.occurred_at, source.inserted_at) == :eq
      refute evidence.encrypted_excerpt == "restful sleep"

      assert {:ok, "restful sleep"} =
               Alethea.Encryption.PatientVault.decrypt(
                 evidence.encrypted_excerpt,
                 clinical_record_dek
               )
    end

    test "unsupported source kind returns unsupported_source without citation side effects", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:error, :unsupported_source} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "summary",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "anything"
                 }
               )

      assert_no_citation_side_effects()
    end

    test "malformed source id returns not_found without citation side effects", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:error, :not_found} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{source_kind: "message", source_id: "not-a-uuid", excerpt: "anything"}
               )

      assert_no_citation_side_effects()
    end

    test "missing source returns not_found without citation side effects", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:error, :not_found} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "message",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "anything"
                 }
               )

      assert_no_citation_side_effects()
    end

    test "foreign source returns not_found without citation side effects", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_patient = create_patient!(professional)

      foreign_source =
        insert_message_source!(
          other_patient,
          patient_dek_for!(professional, other_patient),
          "inbound",
          "Foreign source",
          ~U[2026-09-15 08:30:00Z]
        )

      assert {:error, :not_found} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "message",
                   source_id: foreign_source.id,
                   excerpt: "Foreign source"
                 }
               )

      assert_no_citation_side_effects()
    end

    test "direct citation denies an unauthorized professional without citation side effects", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.cite_evidence_source(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "message",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "anything"
                 }
               )

      assert_no_citation_side_effects()
    end

    test "rejects an excerpt that is not an exact substring of authoritative plaintext", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, source} =
        ClinicalRecord.create_clinical_note(professional, patient.id, "Exact source wording")

      assert {:error, :excerpt_not_found} =
               ClinicalRecord.cite_evidence_source(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   source_kind: "clinical_note",
                   source_id: source.id,
                   excerpt: "exact source wording"
                 }
               )

      assert_no_citation_side_effects()
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

  describe "accept_ai_proposal_into_draft/4 — atomic accept + draft merge (#291)" do
    test "authorized, no prior draft: proposal accepted and draft created in one transaction", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      assert {:ok, %{proposal: accepted, draft: draft}} =
               ClinicalRecord.accept_ai_proposal_into_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 proposal.id
               )

      assert accepted.id == proposal.id
      assert accepted.status == "accepted"

      assert draft.target_behavior_id == target_behavior.id
      assert draft.patient_id == patient.id

      # Verify the draft body contains the proposal text
      assert {:ok, %{body: body}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert body =~ "Patron sugerido por IA"

      # Both audit rows written under the atomic action
      audit_rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and
            a.action == "ai_proposal_accepted_into_draft"
        )
        |> Repo.all()

      assert length(audit_rows) == 2

      resource_types = Enum.map(audit_rows, & &1.resource_type) |> Enum.sort()
      assert resource_types == ["ai_proposal", "functional_analysis_draft"]

      # Both outbox jobs enqueued
      assert_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "authorized, existing draft: proposal text is appended to current draft body", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      # Create an existing draft first
      {:ok, _draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Contenido previo del borrador"
        )

      proposal = create_ai_proposal!(professional, patient, target_behavior)

      assert {:ok, %{proposal: accepted, draft: _draft}} =
               ClinicalRecord.accept_ai_proposal_into_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 proposal.id
               )

      assert accepted.status == "accepted"

      assert {:ok, %{body: body}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert body =~ "Contenido previo del borrador"
      assert body =~ "Patron sugerido por IA"
    end

    test "unauthorized: denies, proposal and draft unchanged", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.accept_ai_proposal_into_draft(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 proposal.id
               )

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "pending"

      assert {:ok, nil} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end

    test "cross-patient id guess fails: proposal and draft unchanged", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      other_professional = create_professional!()
      other_patient = create_patient!(other_professional)

      assert {:error, :not_found} =
               ClinicalRecord.accept_ai_proposal_into_draft(
                 other_professional,
                 other_patient.id,
                 target_behavior.id,
                 proposal.id
               )

      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "pending"
    end

    test "proposal not found: returns not_found error", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:error, :not_found} =
               ClinicalRecord.accept_ai_proposal_into_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 Ecto.UUID.generate()
               )
    end

    test "target behavior not found: returns not_found error", %{
      professional: professional,
      patient: patient
    } do
      assert {:error, :not_found} =
               ClinicalRecord.accept_ai_proposal_into_draft(
                 professional,
                 patient.id,
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end

    test "transaction rollback: when draft persistence fails, proposal status remains pending", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      Repo.query!(
        "ALTER TABLE functional_analysis_drafts ADD CONSTRAINT clinical_record_test_force_failure_draft CHECK (encryption_version <> 2)"
      )

      assert_raise Ecto.ConstraintError, fn ->
        ClinicalRecord.accept_ai_proposal_into_draft(
          professional,
          patient.id,
          target_behavior.id,
          proposal.id
        )
      end

      # Proposal status is NOT accepted (rolled back)
      reloaded = Repo.get!(AIProposal, proposal.id)
      assert reloaded.status == "pending"

      # No draft exists
      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 0

      # No audit row persisted for this action
      audit_rows =
        AuditLog
        |> where([a], a.action == "ai_proposal_accepted_into_draft")
        |> Repo.all()

      assert audit_rows == []

      refute_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{"event" => "ai_proposal_accepted_into_draft"}
      )
    end
  end

  describe "FunctionalAnalysisDraft.default_structure/0" do
    test "contains minimal clinical sections for functional analysis" do
      structure = FunctionalAnalysisDraft.default_structure()

      assert structure =~ "Antecedentes"
      assert structure =~ "Conducta"
      assert structure =~ "Consecuencias"
      assert structure =~ "Función hipotetizada"
      assert structure =~ "Evidencia pendiente / dudas"
    end
  end

  describe "structured functional analysis content" do
    test "round trips normalized content through canonical encrypted plaintext and reuses audit/outbox",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)

      params = %{
        "antecedents_distal" => "Conflict earlier in the day",
        "antecedents_immediate" => "A demand was presented",
        "response_motor" => "Left the room",
        "consequences_short_term" => "The demand stopped"
      }

      assert {:ok, %FunctionalAnalysisDraft{} = draft} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 params
               )

      refute draft.encrypted_body =~ "Conflict earlier in the day"
      assert draft.encryption_version == 2

      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, canonical_plaintext} =
               Alethea.Encryption.PatientVault.decrypt(
                 draft.encrypted_body,
                 clinical_record_dek
               )

      expected_content = FunctionalAnalysisContent.new(params)
      assert canonical_plaintext == FunctionalAnalysisContent.serialize(expected_content)

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content == expected_content
      assert content.organism_sleep == ""
      assert content.previous_notes == ""

      assert Repo.aggregate(
               from(a in AuditLog,
                 where:
                   a.professional_id == ^professional.id and
                     a.action == "functional_analysis_draft_saved"
               ),
               :count
             ) == 1

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{"event" => "functional_analysis_draft_saved"}
      )
    end

    test "returns legacy draft bodies only as previous notes", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "Unclassified historical formulation"
               )

      assert {:ok, content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content == %FunctionalAnalysisContent{
               previous_notes: "Unclassified historical formulation"
             }
    end

    test "preserves professional authorization and patient-target isolation", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()
      other_patient = create_patient!(professional)
      other_target = create_target_behavior!(professional, other_patient)
      params = %{"antecedents_distal" => "Must remain isolated"}

      assert {:error, :unauthorized} =
               ClinicalRecord.upsert_functional_analysis_content(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 params
               )

      assert {:error, :not_found} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 other_target.id,
                 params
               )

      assert {:error, :not_found} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 other_target.id
               )

      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 0
    end

    test "returns no content when no draft exists", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, nil} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end

    test "preserves a draft tombstone and refuses to recreate deleted content", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, draft} =
        ClinicalRecord.upsert_functional_analysis_draft(
          professional,
          patient.id,
          target_behavior.id,
          "Body to delete"
        )

      Repo.delete!(draft)

      tombstone =
        %Tombstone{}
        |> Tombstone.changeset(%{
          resource_type: "functional_analysis_draft",
          resource_id: draft.id,
          target_behavior_id: target_behavior.id,
          patient_id: patient.id,
          deleted_at: ~U[2026-09-16 12:00:00Z],
          deleted_by_id: professional.id,
          trigger: "manual"
        })
        |> Repo.insert!()

      assert {:ok, {:legally_deleted, deleted_at}} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert deleted_at == tombstone.deleted_at

      assert {:error, :legally_deleted} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"antecedents_distal" => "Must not be recreated"}
               )

      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 0
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

  describe "get_functional_analysis_draft/3" do
    test "authorized: returns nil when no draft exists yet", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, nil} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end

    test "authorized: returns the decrypted draft body when one exists", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, _draft} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "Borrador de analisis funcional"
               )

      assert {:ok, %FunctionalAnalysisDraft{} = draft} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert draft.body == "Borrador de analisis funcional"
    end

    test "unauthorized: denies a professional not responsible for the patient", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.get_functional_analysis_draft(
                 other_professional,
                 patient.id,
                 target_behavior.id
               )
    end
  end

  describe "D4 — write to a legally deleted resource (sdd/clinical-record-retention, GitHub #197, task 1.9)" do
    test "update_clinician_observation on a tombstoned resource is denied as :legally_deleted, audited content-free, sibling unaffected",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)

      {:ok, deleted_observation} =
        ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Cuerpo a borrar"
        )

      {:ok, sibling_observation} =
        ClinicalRecord.add_clinician_observation(
          professional,
          patient.id,
          target_behavior.id,
          "Cuerpo hermano"
        )

      # Simulates a legal deletion directly — Retention.legally_delete_record/2
      # (Slice C) is the real primitive that will perform this hard-delete +
      # tombstone insert atomically; here we only need its end state to
      # exercise the D4 gate.
      Repo.delete!(deleted_observation)
      insert_tombstone!(professional, patient, "clinician_observation", deleted_observation.id)

      before_count =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "clinical_record_access_denied"
        )
        |> Repo.aggregate(:count)

      assert {:error, :legally_deleted} =
               ClinicalRecord.update_clinician_observation(
                 professional,
                 patient.id,
                 deleted_observation.id,
                 "Nunca deberia escribirse"
               )

      rows =
        AuditLog
        |> where(
          [a],
          a.professional_id == ^professional.id and a.action == "clinical_record_access_denied"
        )
        |> order_by([a], asc: a.inserted_at)
        |> Repo.all()

      assert length(rows) == before_count + 1
      new_row = List.last(rows)
      assert new_row.resource_id == deleted_observation.id
      assert new_row.resource_type == "clinician_observation"

      haystack = "#{inspect(new_row.details)} #{new_row.action} #{new_row.resource_type}"
      refute haystack =~ "Nunca deberia escribirse"

      # Sibling remains fully readable/writable, unaffected by the deletion.
      assert {:ok, updated_sibling} =
               ClinicalRecord.update_clinician_observation(
                 professional,
                 patient.id,
                 sibling_observation.id,
                 "Cuerpo hermano editado"
               )

      assert updated_sibling.id == sibling_observation.id
      refute updated_sibling.encrypted_body == sibling_observation.encrypted_body
    end

    test "a never-existed observation id still returns :not_found, distinct from :legally_deleted",
         %{professional: professional, patient: patient} do
      assert {:error, :not_found} =
               ClinicalRecord.update_clinician_observation(
                 professional,
                 patient.id,
                 Ecto.UUID.generate(),
                 "irrelevante"
               )
    end

    test "edit_ai_proposal on a tombstoned proposal is denied as :legally_deleted (triangulation: 2nd gate site)",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      Repo.delete!(proposal)
      insert_tombstone!(professional, patient, "ai_proposal", proposal.id)

      assert {:error, :legally_deleted} =
               ClinicalRecord.edit_ai_proposal(
                 professional,
                 patient.id,
                 proposal.id,
                 "No deberia escribirse"
               )
    end

    test "accept_ai_proposal on a tombstoned proposal is denied as :legally_deleted (triangulation: 3rd gate site)",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      proposal = create_ai_proposal!(professional, patient, target_behavior)

      Repo.delete!(proposal)
      insert_tombstone!(professional, patient, "ai_proposal", proposal.id)

      assert {:error, :legally_deleted} =
               ClinicalRecord.accept_ai_proposal(professional, patient.id, proposal.id)
    end
  end

  describe "review_timeline/3 — dual-read by encryption_version (D1/AD1, sdd/clinical-record-retention #197)" do
    test "a v1-encrypted fixture row and a v2-encrypted fixture row on the same patient both decrypt in one review_timeline/3 call",
         %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      t1 = ~U[2026-04-01 09:00:00.000000Z]
      t2 = ~U[2026-04-01 10:00:00.000000Z]

      {:ok, v1_ciphertext} =
        Alethea.Encryption.PatientVault.encrypt(
          "Observacion cifrada con la DEK compartida",
          patient_dek
        )

      v1_observation =
        %ClinicianObservation{}
        |> ClinicianObservation.changeset(%{
          encrypted_body: v1_ciphertext,
          encryption_version: 1,
          occurred_at: t1,
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: target_behavior.id
        })
        |> Repo.insert!()

      {:ok, v2_ciphertext} =
        Alethea.Encryption.PatientVault.encrypt(
          "Observacion cifrada con la DEK de ClinicalRecord",
          clinical_record_dek
        )

      v2_observation =
        %ClinicianObservation{}
        |> ClinicianObservation.changeset(%{
          encrypted_body: v2_ciphertext,
          encryption_version: 2,
          occurred_at: t2,
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: target_behavior.id
        })
        |> Repo.insert!()

      assert {:ok, timeline} =
               ClinicalRecord.review_timeline(professional, patient.id, target_behavior.id)

      assert [item_v1, item_v2] = timeline
      assert item_v1.id == v1_observation.id
      assert item_v1.text == "Observacion cifrada con la DEK compartida"
      assert item_v2.id == v2_observation.id
      assert item_v2.text == "Observacion cifrada con la DEK de ClinicalRecord"
    end
  end

  describe "dismissed evidence suggestions" do
    test "authorized professional dismisses by chunk id and lists ids and records", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      older_chunk_id = Ecto.UUID.generate()
      newer_chunk_id = Ecto.UUID.generate()

      assert {:ok, %DismissedEvidenceSuggestion{} = older} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   chunk_id: older_chunk_id,
                   dismissed_at: ~U[2026-09-23 10:00:00.000000Z]
                 }
               )

      assert {:ok, %DismissedEvidenceSuggestion{} = newer} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 newer_chunk_id
               )

      assert older.chunk_id == older_chunk_id
      assert newer.chunk_id == newer_chunk_id

      assert {:ok, ids} =
               ClinicalRecord.list_dismissed_suggestion_ids(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert MapSet.new(ids) == MapSet.new([older_chunk_id, newer_chunk_id])

      assert {:ok, [first, second]} =
               ClinicalRecord.list_dismissed_evidence_suggestions(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert [first.id, second.id] == [newer.id, older.id]
    end

    test "dismisses map attributes and lists distinct chunk and resource ids", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      chunk_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      assert {:ok, dismissal} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{
                   chunk_id: chunk_id,
                   resource_id: resource_id,
                   resource_type: "clinical_note"
                 }
               )

      assert dismissal.resource_id == resource_id
      assert dismissal.resource_type == "clinical_note"

      assert {:ok, ids} =
               ClinicalRecord.list_dismissed_suggestion_ids(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert MapSet.new(ids) == MapSet.new([chunk_id, resource_id])
    end

    test "dismissal is idempotent and writes one success audit", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      chunk_id = Ecto.UUID.generate()

      assert {:ok, first} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 chunk_id
               )

      assert {:ok, second} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 chunk_id
               )

      assert second.id == first.id
      assert Repo.aggregate(DismissedEvidenceSuggestion, :count) == 1

      assert [audit] =
               AuditLog
               |> where([a], a.action == "evidence_suggestion_dismissed")
               |> Repo.all()

      assert audit.resource_type == "dismissed_evidence_suggestion"
      assert audit.resource_id == first.id
      assert audit.professional_id == professional.id
      assert audit.details == %{"outcome" => "success"}
    end

    test "unauthorized professional cannot dismiss and logs denial", %{
      patient: patient
    } do
      professional = create_professional!()

      owner = Repo.get!(Alethea.Accounts.Professional, patient.professional_id)
      target_behavior = create_target_behavior!(owner, patient)

      assert {:error, :unauthorized} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 Ecto.UUID.generate()
               )

      assert Repo.aggregate(DismissedEvidenceSuggestion, :count) == 0

      assert [audit] =
               AuditLog
               |> where([a], a.professional_id == ^professional.id)
               |> where([a], a.action == "clinical_record_access_denied")
               |> Repo.all()

      assert audit.resource_id == patient.id
      assert audit.details == %{"outcome" => "denied"}
    end

    test "cross-patient target behavior returns not found and logs denial", %{
      professional: professional,
      patient: patient
    } do
      other_patient = create_patient!(professional)
      other_target = create_target_behavior!(professional, other_patient)

      assert {:error, :not_found} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 other_target.id,
                 Ecto.UUID.generate()
               )

      assert Repo.aggregate(DismissedEvidenceSuggestion, :count) == 0

      assert [audit] =
               AuditLog
               |> where([a], a.action == "clinical_record_access_denied")
               |> where([a], a.resource_type == "target_behavior")
               |> where([a], a.resource_id == ^other_target.id)
               |> Repo.all()

      assert audit.professional_id == professional.id
      assert audit.details == %{"outcome" => "denied"}
    end

    test "deleting a target behavior cascades to its dismissals", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      assert {:ok, dismissal} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 Ecto.UUID.generate()
               )

      Repo.delete!(target_behavior)

      refute Repo.get(DismissedEvidenceSuggestion, dismissal.id)
    end
  end

  describe "cross-patient target_behavior ownership (GitHub #289)" do
    # Same professional owns BOTH patients, so `get_patient_for_professional/2`
    # passes for either — the only thing standing between patient A's URL and
    # patient B's target behavior is the (patient_id, target_behavior_id) check.
    setup %{professional: professional, patient: patient_a} do
      patient_b = create_patient!(professional)
      target_a = create_target_behavior!(professional, patient_a)
      target_b = create_target_behavior!(professional, patient_b)

      %{patient_a: patient_a, patient_b: patient_b, target_a: target_a, target_b: target_b}
    end

    test "review_timeline/3 rejects a target behavior of another patient",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.review_timeline(professional, patient_a.id, target_b.id)
    end

    test "review_timeline/3 rejects a malformed target behavior id without raising",
         %{professional: professional, patient_a: patient_a} do
      assert {:error, :not_found} =
               ClinicalRecord.review_timeline(professional, patient_a.id, "not-a-uuid")
    end

    test "review_timeline/3 still works for the patient's own target behavior",
         %{professional: professional, patient_a: patient_a, target_a: target_a} do
      assert {:ok, []} = ClinicalRecord.review_timeline(professional, patient_a.id, target_a.id)
    end

    test "add_clinician_observation/4 rejects a cross-patient target and inserts nothing",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.add_clinician_observation(
                 professional,
                 patient_a.id,
                 target_b.id,
                 "cross-patient body"
               )

      assert Repo.aggregate(ClinicianObservation, :count) == 0
    end

    test "add_consultation_evidence/4 rejects a cross-patient target and inserts nothing",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.add_consultation_evidence(
                 professional,
                 patient_a.id,
                 target_b.id,
                 %{
                   source_kind: "clinical_note",
                   source_id: Ecto.UUID.generate(),
                   excerpt: "cross-patient excerpt",
                   occurred_at: DateTime.utc_now()
                 }
               )

      assert Repo.aggregate(ConsultationEvidence, :count) == 0
    end

    test "request_ai_proposals/3 rejects a cross-patient target: no job, no audit",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.request_ai_proposals(professional, patient_a.id, target_b.id)

      assert all_enqueued(worker: "AletheaJobs.AIProposalWorker") == []

      assert [] =
               AuditLog
               |> where([a], a.action == "ai_proposals_requested")
               |> Repo.all()
    end

    test "upsert_functional_analysis_draft/4 rejects a cross-patient target and inserts nothing",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.upsert_functional_analysis_draft(
                 professional,
                 patient_a.id,
                 target_b.id,
                 "cross-patient draft"
               )

      assert Repo.aggregate(FunctionalAnalysisDraft, :count) == 0
    end

    test "get_functional_analysis_draft/3 rejects a cross-patient target",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient_a.id,
                 target_b.id
               )
    end

    test "a cross-patient attempt writes a content-free denial audit row",
         %{professional: professional, patient_a: patient_a, target_b: target_b} do
      assert {:error, :not_found} =
               ClinicalRecord.review_timeline(professional, patient_a.id, target_b.id)

      assert [row] =
               AuditLog
               |> where([a], a.action == "clinical_record_access_denied")
               |> where([a], a.resource_type == "target_behavior")
               |> Repo.all()

      assert row.professional_id == professional.id
      assert row.resource_id == target_b.id
      assert row.details == %{"outcome" => "denied"}
    end

    test "a malformed target id is audited without echoing the id",
         %{professional: professional, patient_a: patient_a} do
      assert {:error, :not_found} =
               ClinicalRecord.review_timeline(professional, patient_a.id, "not-a-uuid")

      assert [row] =
               AuditLog
               |> where([a], a.action == "clinical_record_access_denied")
               |> where([a], a.resource_type == "target_behavior")
               |> Repo.all()

      assert row.resource_id == nil
    end

    test "get_target_behavior/3 decrypts description and attaches patient",
         %{
           professional: professional,
           patient_a: patient_a,
           target_a: target_a
         } do
      assert {:ok, %TargetBehavior{description: description, patient: patient}} =
               ClinicalRecord.get_target_behavior(professional, patient_a.id, target_a.id)

      assert is_binary(description)
      assert description != "[No disponible]"
      assert patient.id == patient_a.id
      assert patient.alias == patient_a.alias
    end

    test "get_target_behavior/3 returns the row only for the owning patient",
         %{
           professional: professional,
           patient_a: patient_a,
           target_a: target_a,
           target_b: target_b
         } do
      assert {:ok, %TargetBehavior{id: id}} =
               ClinicalRecord.get_target_behavior(professional, patient_a.id, target_a.id)

      assert id == target_a.id

      assert {:error, :not_found} =
               ClinicalRecord.get_target_behavior(professional, patient_a.id, target_b.id)
    end

    test "get_target_behavior/3 denies a professional not responsible for the patient",
         %{patient_a: patient_a, target_a: target_a} do
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.get_target_behavior(other_professional, patient_a.id, target_a.id)
    end
  end

  describe "suggest_evidence_candidates/4" do
    test "authorized professional receives ranked candidates with affinity metadata", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      resource_id = insert_rag_chunk!(professional, patient, "Conducta objetivo observada")
      stub_rag_query_embedding()

      assert {:ok, [candidate]} =
               ClinicalRecord.suggest_evidence_candidates(
                 professional,
                 patient.id,
                 target_behavior.id,
                 limit: 1
               )

      assert candidate.source_resource_id == resource_id
      assert is_integer(candidate.match_percentage)
      assert candidate.affinity_badge.percentage == candidate.match_percentage
      assert candidate.affinity_badge.tier == candidate.affinity_tier
    end

    test "excludes chunks dismissed for the target behavior", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      dismissed_resource = insert_rag_chunk!(professional, patient, "Conducta descartada")
      kept_resource = insert_rag_chunk!(professional, patient, "Conducta conservada")
      dismissed_chunk = Repo.get_by!(Chunk, source_resource_id: dismissed_resource)

      assert {:ok, _dismissal} =
               ClinicalRecord.dismiss_evidence_suggestion(
                 professional,
                 patient.id,
                 target_behavior.id,
                 dismissed_chunk.id
               )

      stub_rag_query_embedding()

      assert {:ok, candidates} =
               ClinicalRecord.suggest_evidence_candidates(
                 professional,
                 patient.id,
                 target_behavior.id,
                 []
               )

      assert Enum.map(candidates, & &1.source_resource_id) == [kept_resource]
    end

    test "blank target behavior description returns an empty list without embedding", %{
      professional: professional,
      patient: patient
    } do
      assert {:ok, target_behavior} =
               ClinicalRecord.create_target_behavior(professional, patient.id, "   ")

      deny_rag_query_embedding()

      assert {:ok, []} =
               ClinicalRecord.suggest_evidence_candidates(
                 professional,
                 patient.id,
                 target_behavior.id,
                 []
               )
    end

    test "non-treating professional is denied", %{professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)
      stranger = create_professional!()

      assert {:error, reason} =
               ClinicalRecord.suggest_evidence_candidates(
                 stranger,
                 patient.id,
                 target_behavior.id,
                 []
               )

      assert reason in [:unauthorized, :not_found]
    end
  end

  describe "search_evidence_candidates/5" do
    test "natural-language query returns matching candidates", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)

      resource_id =
        insert_rag_chunk!(professional, patient, "Angustia intensa en el supermercado")

      stub_rag_query_embedding()

      assert {:ok, [candidate]} =
               ClinicalRecord.search_evidence_candidates(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "angustia en el supermercado",
                 limit: 1
               )

      assert candidate.source_resource_id == resource_id
      assert candidate.content == "Angustia intensa en el supermercado"
      assert is_integer(candidate.match_percentage)
    end

    test "blank query returns an empty list without invoking embedding", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      deny_rag_query_embedding()

      assert {:ok, []} =
               ClinicalRecord.search_evidence_candidates(
                 professional,
                 patient.id,
                 target_behavior.id,
                 "   ",
                 []
               )
    end
  end

  defp deny_rag_query_embedding do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)
  end

  defp stub_rag_query_embedding do
    deny_rag_query_embedding()
    vector = [1.0 | List.duplicate(0.0, 1023)]

    Alethea.AI.EmbeddingsMock
    |> stub(:embed, fn _query, [] -> {:ok, vector} end)
    |> stub(:dimensions, fn -> 1024 end)
    |> stub(:model, fn -> "fake-embeddings-bge-m3" end)
  end

  defp insert_rag_chunk!(professional, patient, text) do
    resource_id = Ecto.UUID.generate()

    {:ok, ciphertext} =
      Alethea.Encryption.PatientVault.encrypt(text, patient_dek_for!(professional, patient))

    attrs = [
      %{
        source_resource_type: "clinical_note",
        source_resource_id: resource_id,
        chunk_index: 0,
        encrypted_content: ciphertext,
        embedding: [1.0 | List.duplicate(0.0, 1023)],
        embedding_model: "fake-embeddings-bge-m3",
        token_count: 10,
        full_event: true,
        source_occurred_at: DateTime.utc_now(),
        patient_id: patient.id,
        professional_id: professional.id
      }
    ]

    {:ok, _rows} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)
    resource_id
  end

  defp insert_tombstone!(professional, patient, resource_type, resource_id) do
    %Tombstone{}
    |> Tombstone.changeset(%{
      resource_type: resource_type,
      resource_id: resource_id,
      patient_id: patient.id,
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_id: professional.id,
      trigger: "manual"
    })
    |> Repo.insert!()
  end

  defp insert_clinical_note_source!(
         professional,
         patient,
         dek,
         encryption_version,
         body,
         occurred_at
       ) do
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt(body, dek)

    %ClinicalNote{inserted_at: occurred_at}
    |> ClinicalNote.changeset(%{
      encrypted_body: ciphertext,
      encryption_version: encryption_version,
      patient_id: patient.id,
      professional_id: professional.id
    })
    |> Repo.insert!()
  end

  defp insert_message_source!(patient, dek, direction, content, occurred_at) do
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt(content, dek)

    %Journaling.Message{}
    |> Journaling.Message.changeset(%{
      direction: direction,
      behavior_type: "spontaneous",
      encrypted_content: ciphertext,
      encryption_version: 1,
      timestamp: occurred_at,
      patient_id: patient.id
    })
    |> Repo.insert!()
  end

  defp patient_dek_for!(professional, patient) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    dek
  end

  defp assert_no_citation_side_effects do
    assert Repo.aggregate(ConsultationEvidence, :count) == 0

    assert AuditLog
           |> where([audit], audit.action == "consultation_evidence_created")
           |> Repo.aggregate(:count) == 0

    refute_enqueued(
      worker: ClinicalRecordOutboxWorker,
      args: %{"event" => "consultation_evidence_created"}
    )
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
