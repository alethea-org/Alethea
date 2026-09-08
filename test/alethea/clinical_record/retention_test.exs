defmodule Alethea.ClinicalRecord.RetentionTest do
  @moduledoc """
  RED-phase specs for `Alethea.ClinicalRecord.Retention`
  (sdd/clinical-record-retention, GitHub #197, Phase 3/Slice C, tasks
  3.1/3.3/3.5): `eligible_records/2` per table (own-clock independence,
  AD3 `GREATEST` stricter-minimum, `left_join` correctness, identifiers
  -only `select:`), `legally_delete_record/2` (hard-delete + tombstone +
  audit + RAG purge enqueue + zero-remaining crypto-erasure firing
  exactly once, never with an active sibling), and
  `legally_delete_patient_record/3` (BR11 bounded iteration, partial
  result on mid-iteration failure, not rolled back).
  """
  use Alethea.DataCase, async: true
  use Oban.Testing, repo: Alethea.Repo

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.{AuditLog, EncryptionKey}

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    Lifecycle,
    Retention,
    TargetBehavior,
    Tombstone
  }

  alias AletheaJobs.ClinicalRecordOutboxWorker
  alias Alethea.Repo

  @password "supersecret12"
  @baseline_days 3650

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  describe "eligible_records/2 — own-clock independence (spec: no cross-restart)" do
    test "a fresh clinician_observation on a very old target_behavior is not eligible on the parent's clock",
         %{professional: professional, patient: patient} do
      target_behavior =
        insert_target_behavior!(patient, professional, inserted_at: days_ago(3651))

      fresh_observation = insert_clinician_observation!(patient, professional, target_behavior)

      refute Retention.eligible_records(ClinicianObservation)
             |> Enum.any?(&(&1.resource_id == fresh_observation.id))
    end

    test "an old clinician_observation past the baseline is eligible regardless of a fresh sibling target_behavior",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)

      old_observation =
        insert_clinician_observation!(patient, professional, target_behavior,
          updated_at: days_ago(@baseline_days + 1)
        )

      assert Retention.eligible_records(ClinicianObservation)
             |> Enum.any?(&(&1.resource_id == old_observation.id))
    end
  end

  describe "eligible_records/2 — AD3 stricter minimum wins (GREATEST)" do
    test "an override longer than the baseline keeps a record ineligible past the baseline threshold",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)
      {:ok, _lifecycle} = Lifecycle.set_retention_minimum(professional, patient.id, 4000)

      record =
        insert_clinician_observation!(patient, professional, target_behavior,
          updated_at: days_ago(@baseline_days + 50)
        )

      refute Retention.eligible_records(ClinicianObservation)
             |> Enum.any?(&(&1.resource_id == record.id))
    end

    test "the same override record becomes eligible once it ages past the override, not just the baseline",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)
      {:ok, _lifecycle} = Lifecycle.set_retention_minimum(professional, patient.id, 4000)

      record =
        insert_clinician_observation!(patient, professional, target_behavior,
          updated_at: days_ago(4001)
        )

      assert Retention.eligible_records(ClinicianObservation)
             |> Enum.any?(&(&1.resource_id == record.id))
    end
  end

  describe "eligible_records/2 — left_join correctness" do
    test "a patient with no lifecycle row at all is still eligible", %{
      professional: professional,
      patient: patient
    } do
      refute Repo.get_by(Lifecycle, patient_id: patient.id)

      target_behavior = insert_target_behavior!(patient, professional)

      record =
        insert_clinician_observation!(patient, professional, target_behavior,
          updated_at: days_ago(@baseline_days + 1)
        )

      assert Retention.eligible_records(ClinicianObservation)
             |> Enum.any?(&(&1.resource_id == record.id))
    end

    test "an active legal hold excludes an otherwise-eligible record", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = insert_target_behavior!(patient, professional)

      record =
        insert_clinician_observation!(patient, professional, target_behavior,
          updated_at: days_ago(@baseline_days + 1)
        )

      {:ok, _lifecycle} = Lifecycle.apply_hold(professional, patient.id)

      refute Retention.eligible_records(ClinicianObservation)
             |> Enum.any?(&(&1.resource_id == record.id))
    end
  end

  describe "eligible_records/2 — select: identifiers only (mechanical no-decrypt proof)" do
    test "the returned map carries exactly the 5 identifier keys, never an encrypted_* column", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = insert_target_behavior!(patient, professional)

      record =
        insert_clinician_observation!(patient, professional, target_behavior,
          updated_at: days_ago(@baseline_days + 1)
        )

      [result] =
        Retention.eligible_records(ClinicianObservation)
        |> Enum.filter(&(&1.resource_id == record.id))

      assert Map.keys(result) |> Enum.sort() ==
               [:patient_id, :professional_id, :resource_id, :resource_type, :retention_at]

      assert result.resource_type == "clinician_observation"
      assert result.patient_id == patient.id
      assert result.professional_id == professional.id
      assert %DateTime{} = result.retention_at
    end
  end

  describe "legally_delete_record/2 — hard-delete + tombstone + audit + RAG purge" do
    test "manual deletion hard-deletes the row, tombstones it, audits by the acting professional, and enqueues the RAG purge event",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)
      observation = insert_clinician_observation!(patient, professional, target_behavior)

      assert {:ok, tombstone} =
               Retention.legally_delete_record({"clinician_observation", observation.id},
                 actor: professional,
                 trigger: "manual"
               )

      refute Repo.get(ClinicianObservation, observation.id)

      assert tombstone.resource_type == "clinician_observation"
      assert tombstone.resource_id == observation.id
      assert tombstone.patient_id == patient.id
      assert tombstone.target_behavior_id == target_behavior.id
      assert tombstone.trigger == "manual"
      assert tombstone.deleted_by_id == professional.id

      audit_rows = audit_rows("clinical_record_legally_deleted", observation.id)
      assert length(audit_rows) == 1
      assert hd(audit_rows).professional_id == professional.id

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{
          "event" => "clinical_record_legally_deleted",
          "resource_type" => "clinician_observation",
          "resource_id" => observation.id,
          "patient_id" => patient.id,
          "professional_id" => professional.id
        }
      )
    end

    test "sweep-triggered deletion attributes the audit row to the record's own author and leaves tombstone.deleted_by_id nil",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)
      observation = insert_clinician_observation!(patient, professional, target_behavior)

      assert {:ok, tombstone} =
               Retention.legally_delete_record({"clinician_observation", observation.id},
                 actor: :system,
                 trigger: "sweep"
               )

      assert tombstone.trigger == "sweep"
      assert tombstone.deleted_by_id == nil

      audit_rows = audit_rows("clinical_record_legally_deleted", observation.id)
      assert length(audit_rows) == 1
      assert hd(audit_rows).professional_id == professional.id
    end

    test "deleting a resource_id that does not exist returns :not_found" do
      assert {:error, :not_found} =
               Retention.legally_delete_record({"clinician_observation", Ecto.UUID.generate()},
                 actor: :system,
                 trigger: "sweep"
               )
    end

    test "an active legal hold denies deletion, audits the denial, and leaves the record intact",
         %{
           professional: professional,
           patient: patient
         } do
      target_behavior = insert_target_behavior!(patient, professional)
      observation = insert_clinician_observation!(patient, professional, target_behavior)
      {:ok, _lifecycle} = Lifecycle.apply_hold(professional, patient.id)

      assert {:error, :legal_hold_active} =
               Retention.legally_delete_record({"clinician_observation", observation.id},
                 actor: professional,
                 trigger: "manual"
               )

      assert Repo.get(ClinicianObservation, observation.id)
      denied_rows = audit_rows("clinical_record_access_denied", observation.id)
      assert length(denied_rows) == 1
    end
  end

  describe "legally_delete_record/2 — terminal crypto-erasure (D1/BR3, race-safety via queue concurrency 1)" do
    test "the CR key is destroyed exactly once, only when the patient's last remaining record is deleted — never while a sibling exists",
         %{professional: professional, patient: patient} do
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, _cr_dek} = Accounts.ensure_clinical_record_dek(patient, kek)
      assert Repo.get_by(EncryptionKey, patient_id: patient.id, type: "patient_clinical_record")

      target_behavior = insert_target_behavior!(patient, professional)
      observation = insert_clinician_observation!(patient, professional, target_behavior)

      # A sibling (`target_behavior`) still exists after this deletion —
      # the CR key must survive.
      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"clinician_observation", observation.id},
                 actor: professional,
                 trigger: "manual"
               )

      assert Repo.get_by(EncryptionKey, patient_id: patient.id, type: "patient_clinical_record")
      assert audit_rows("clinical_record_key_destroyed", patient.id) == []

      # This is now the patient's last remaining record across all six
      # tables — this deletion must destroy the CR key.
      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"target_behavior", target_behavior.id},
                 actor: professional,
                 trigger: "manual"
               )

      refute Repo.get_by(EncryptionKey, patient_id: patient.id, type: "patient_clinical_record")

      destroy_rows = audit_rows("clinical_record_key_destroyed", patient.id)
      assert length(destroy_rows) == 1
    end

    test "the shared patient DEK is never touched by the CR key's terminal erasure", %{
      professional: professional,
      patient: patient
    } do
      {:ok, kek} = Accounts.load_professional_kek(professional)
      {:ok, patient_dek_before} = Accounts.load_patient_dek(patient, kek)
      {:ok, _cr_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      target_behavior = insert_target_behavior!(patient, professional)

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"target_behavior", target_behavior.id},
                 actor: professional,
                 trigger: "manual"
               )

      refute Repo.get_by(EncryptionKey, patient_id: patient.id, type: "patient_clinical_record")
      assert {:ok, ^patient_dek_before} = Accounts.load_patient_dek(patient, kek)
      assert Repo.get_by(EncryptionKey, patient_id: patient.id, type: "patient")
    end
  end

  describe "legally_delete_patient_record/3 — BR11 bounded iteration (AD4, not one transaction)" do
    test "every one of the patient's records across the tables is legally deleted, gated once by the hold check",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)
      observation = insert_clinician_observation!(patient, professional, target_behavior)
      note = insert_clinical_note!(patient, professional)

      assert {:ok, %{deleted: 3, tombstones: tombstones}} =
               Retention.legally_delete_patient_record(professional, patient.id)

      assert length(tombstones) == 3
      assert Enum.all?(tombstones, &(&1.trigger == "manual"))

      refute Repo.get(ClinicianObservation, observation.id)
      refute Repo.get(ClinicalNote, note.id)
      refute Repo.get(TargetBehavior, target_behavior.id)
    end

    test "a held patient blocks whole-patient deletion entirely, with no state change", %{
      professional: professional,
      patient: patient
    } do
      target_behavior = insert_target_behavior!(patient, professional)
      {:ok, _lifecycle} = Lifecycle.apply_hold(professional, patient.id)

      assert {:error, :legal_hold_active} =
               Retention.legally_delete_patient_record(professional, patient.id)

      assert Repo.get(TargetBehavior, target_behavior.id)
    end

    test "an unauthorized professional cannot legally delete another professional's patient record",
         %{
           patient: patient
         } do
      other = create_professional!()

      assert {:error, :unauthorized} =
               Retention.legally_delete_patient_record(other, patient.id)
    end

    test "a mid-iteration failure halts, reports the partial count, and does NOT roll back already-deleted records",
         %{professional: professional, patient: patient} do
      target_behavior = insert_target_behavior!(patient, professional)
      observation = insert_clinician_observation!(patient, professional, target_behavior)

      ai_proposal = insert_ai_proposal!(patient, professional, target_behavior)

      # Pre-poison the AI proposal's deletion by inserting its tombstone
      # out of band (its underlying row still exists) — this forces
      # `legally_delete_record/2` to halt on this exact ref with
      # `:already_deleted`, mid-iteration, deterministically.
      {:ok, _poison_tombstone} =
        %Tombstone{}
        |> Tombstone.changeset(%{
          resource_type: "ai_proposal",
          resource_id: ai_proposal.id,
          patient_id: patient.id,
          target_behavior_id: target_behavior.id,
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          trigger: "manual"
        })
        |> Repo.insert()

      assert {:error, {:partial, 1, :already_deleted}} =
               Retention.legally_delete_patient_record(professional, patient.id)

      # The observation (iterated before the poisoned ai_proposal, per
      # `Retention`'s table order) was genuinely deleted and NOT rolled
      # back despite the overall call reporting an error.
      refute Repo.get(ClinicianObservation, observation.id)
      assert audit_rows("clinical_record_legally_deleted", observation.id) != []

      # The target_behavior (iterated after the poisoned ai_proposal) was
      # never reached — reduce_while halts immediately, it does not skip
      # ahead.
      assert Repo.get(TargetBehavior, target_behavior.id)
    end
  end

  defp audit_rows(action, resource_id) do
    AuditLog
    |> where([a], a.action == ^action and a.resource_id == ^resource_id)
    |> Repo.all()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
  end

  defp insert_target_behavior!(patient, professional, opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, now())

    attrs = %{
      id: Ecto.UUID.generate(),
      encrypted_description: <<1, 2, 3>>,
      encryption_version: 1,
      patient_id: patient.id,
      professional_id: professional.id,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }

    {1, [row]} = Repo.insert_all(TargetBehavior, [attrs], returning: true)
    row
  end

  defp insert_clinical_note!(patient, professional, opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, now())

    attrs = %{
      id: Ecto.UUID.generate(),
      encrypted_body: <<1, 2, 3>>,
      encryption_version: 1,
      patient_id: patient.id,
      professional_id: professional.id,
      inserted_at: inserted_at
    }

    {1, [row]} = Repo.insert_all(ClinicalNote, [attrs], returning: true)
    row
  end

  defp insert_clinician_observation!(patient, professional, target_behavior, opts \\ []) do
    updated_at = Keyword.get(opts, :updated_at, now())
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    attrs = %{
      id: Ecto.UUID.generate(),
      encrypted_body: <<1, 2, 3>>,
      encryption_version: 1,
      occurred_at: occurred_at,
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id,
      inserted_at: now(),
      updated_at: updated_at
    }

    {1, [row]} = Repo.insert_all(ClinicianObservation, [attrs], returning: true)
    row
  end

  defp insert_ai_proposal!(patient, professional, target_behavior, opts \\ []) do
    updated_at = Keyword.get(opts, :updated_at, now())
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    attrs = %{
      id: Ecto.UUID.generate(),
      encrypted_original_text: <<1, 2, 3>>,
      encrypted_text: <<1, 2, 3>>,
      encryption_version: 1,
      status: "pending",
      model_version: "test-model",
      occurred_at: occurred_at,
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id,
      inserted_at: now(),
      updated_at: updated_at
    }

    {1, [row]} = Repo.insert_all(AIProposal, [attrs], returning: true)
    row
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "retention-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Retention"
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
