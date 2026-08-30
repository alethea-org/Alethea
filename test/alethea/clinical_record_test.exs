defmodule Alethea.ClinicalRecordTest do
  @moduledoc """
  RED-phase specs for `Alethea.ClinicalRecord.create_target_behavior/3`
  (sdd/clinical-record-foundation, task 3.1, GitHub #194). GREEN
  implementation lands in task 3.2 — until then these tests fail with
  `UndefinedFunctionError`, not a compile error.

  `async: false`: the atomicity test issues a raw `ALTER TABLE ...
  ADD CONSTRAINT` DDL statement, which takes a Postgres ACCESS
  EXCLUSIVE lock on `target_behaviors` for the whole test — that would
  block any async test (in this file or elsewhere) concurrently
  reading/writing the same table (Judgment Day finding, 2026-08-30).
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.TargetBehavior
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
