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
  alias Alethea.ClinicalRecord.{ClinicalNote, TargetBehavior}
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
