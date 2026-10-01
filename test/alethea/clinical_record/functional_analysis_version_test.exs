defmodule Alethea.ClinicalRecord.FunctionalAnalysisVersionTest do
  use Alethea.DataCase, async: false

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.FunctionalAnalysisVersion
  alias Alethea.ClinicalRecord.FunctionalAnalysisDraft
  alias Alethea.ClinicalRecord.FunctionalAnalysisContent
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Oban.Job
  import Ecto.Query

  test "registers the exact persisted draft ciphertext with an encrypted mandatory note" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    content =
      FunctionalAnalysisContent.new(%{
        "antecedents_distal" => "Trigger A",
        "antecedents_immediate" => "Trigger B",
        "organism_sleep" => "Sleep",
        "organism_pain_or_discomfort" => "Pain",
        "organism_hunger_or_nutrition" => "Nutrition",
        "organism_learning_history" => "History",
        "response_physiological" => "Physiology",
        "response_cognitive" => "Cognition",
        "response_motor" => "Motor",
        "consequences_short_term" => "Immediate outcome",
        "consequences_long_term" => "Long-term outcome",
        "previous_notes" => "Prior clinician notes"
      })

    body = FunctionalAnalysisContent.serialize(content)

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(professional, patient.id, target.id, body)

    assert {:ok, []} =
             ClinicalRecord.list_functional_analysis_versions(professional, patient.id, target.id)

    assert {:ok, version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft.lock_version,
               "  Revisión clínica confirmada  "
             )

    assert version.version_number == 1
    assert version.professional_id == professional.id
    assert %DateTime{} = version.inserted_at
    assert version.encrypted_body == draft.encrypted_body
    refute version.encrypted_body =~ "Conducta"
    refute version.encrypted_change_note =~ "Revisión clínica"

    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_clinical_record_dek(patient, kek)
    assert {:ok, note} = PatientVault.decrypt(version.encrypted_change_note, dek)
    assert note == "Revisión clínica confirmada"

    audit = Repo.get_by!(AuditLog, resource_id: version.id)
    assert audit.action == "functional_analysis_version_registered"
    assert audit.details == %{"outcome" => "success"}

    job = Enum.find(Repo.all(Job), &(&1.args["resource_id"] == version.id))
    assert job.args["event"] == "functional_analysis_version_registered"

    assert Map.keys(job.args) |> Enum.sort() ==
             Enum.sort(["event", "resource_type", "resource_id", "patient_id", "professional_id"])

    refute inspect(job.args) =~ "Prior clinician notes"
    refute inspect(job.args) =~ "Revisión clínica confirmada"

    assert {:ok, [listed]} =
             ClinicalRecord.list_functional_analysis_versions(professional, patient.id, target.id)

    assert listed.id == version.id
    assert listed.version_number == 1
    assert listed.body == body
    assert {:structured, ^content} = FunctionalAnalysisContent.parse(listed.body)
    assert listed.change_note == "Revisión clínica confirmada"
    assert listed.professional.id == professional.id

    assert {:ok, loaded} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               version.id
             )

    assert loaded.body == body
    assert %FunctionalAnalysisDraft{} = Repo.get(FunctionalAnalysisDraft, draft.id)
  end

  test "rejects blank, oversized, stale, and absent draft registrations" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    assert {:error, :invalid_change_note} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               1,
               "   "
             )

    assert {:error, :draft_not_found} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               1,
               "Initial"
             )

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Primera versión"
      )

    assert {:error, :invalid_change_note} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft.lock_version,
               String.duplicate("x", 501)
             )

    assert {:error, :conflict} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft.lock_version + 1,
               "Stale"
             )
  end

  test "assigns chronological per-target numbering and rejects cross-patient reads" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, first_draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Primera"
      )

    assert {:ok, first} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               first_draft.lock_version,
               "Primera nota"
             )

    {:ok, second_draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Segunda"
      )

    assert {:ok, second} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               second_draft.lock_version,
               "Segunda nota"
             )

    assert second.version_number == first.version_number + 1

    assert {:ok, [listed_first, listed_second]} =
             ClinicalRecord.list_functional_analysis_versions(professional, patient.id, target.id)

    assert [listed_first.id, listed_second.id] == [first.id, second.id]

    {:ok, independent_target} =
      ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta independiente")

    {:ok, independent_draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        independent_target.id,
        "Independent target draft"
      )

    assert {:ok, independent_version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               independent_target.id,
               independent_draft.lock_version,
               "Independent target approval"
             )

    assert independent_version.version_number == 1

    other = create_professional!()

    assert {:error, :unauthorized} =
             ClinicalRecord.list_functional_analysis_versions(other, patient.id, target.id)
  end

  test "registration never reuses a legally deleted version number" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, first_draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "First persisted draft"
      )

    assert {:ok, first} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               first_draft.lock_version,
               "First approved"
             )

    {:ok, second_draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Second persisted draft"
      )

    assert {:ok, second} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               second_draft.lock_version,
               "Second approved"
             )

    assert [first.version_number, second.version_number] == [1, 2]

    assert {:ok, _tombstone} =
             Alethea.ClinicalRecord.Retention.legally_delete_record(
               {"functional_analysis_version", second.id},
               actor: professional,
               trigger: "manual"
             )

    {:ok, third_draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Third persisted draft"
      )

    assert {:ok, third} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               third_draft.lock_version,
               "Third approved"
             )

    assert third.version_number == 3
    refute Repo.get(FunctionalAnalysisVersion, second.id)

    audit = Repo.get_by!(AuditLog, resource_id: third.id)
    assert audit.details == %{"outcome" => "success"}
    refute inspect(audit) =~ "Third persisted draft"
    refute inspect(audit) =~ "Third approved"

    job = Enum.find(Repo.all(Job), &(&1.args["resource_id"] == third.id))
    assert job
    refute inspect(job.args) =~ "Third persisted draft"
    refute inspect(job.args) =~ "Third approved"
  end

  test "concurrent registrations serialize into unique monotonic numbers" do
    {professional, patient, target, draft} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        professional = create_professional!()
        patient = create_patient!(professional)

        {:ok, target} =
          ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

        {:ok, draft} =
          ClinicalRecord.upsert_functional_analysis_draft(
            professional,
            patient.id,
            target.id,
            "Concurrent snapshot"
          )

        {professional, patient, target, draft}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM oban_jobs WHERE args->>'professional_id' = $1", [professional.id])

        Repo.query!("DELETE FROM audit_logs WHERE professional_id = $1", [
          Ecto.UUID.dump!(professional.id)
        ])

        Repo.query!("DELETE FROM patients WHERE id = $1", [Ecto.UUID.dump!(patient.id)])

        Repo.query!("DELETE FROM professionals WHERE id = $1", [
          Ecto.UUID.dump!(professional.id)
        ])
      end)
    end)

    task_supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {:registration_ready, self()})

          receive do
            :register ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                ClinicalRecord.register_functional_analysis_version(
                  professional,
                  patient.id,
                  target.id,
                  draft.lock_version,
                  "Concurrent sign-off"
                )
              end)
          end
        end)
      end

    task_pids =
      for _ <- 1..2 do
        assert_receive {:registration_ready, pid}, 5_000
        pid
      end

    Enum.each(task_pids, &send(&1, :register))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 2

    assert Enum.map(results, fn {:ok, version} -> version.version_number end) |> Enum.sort() == [
             1,
             2
           ]
  end

  test "the database rejects every version update but permits legal deletion" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Persistida"
      )

    {:ok, version} =
      ClinicalRecord.register_functional_analysis_version(
        professional,
        patient.id,
        target.id,
        draft.lock_version,
        "Nota"
      )

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE functional_analysis_versions SET version_number = 99 WHERE id = $1", [
        Ecto.UUID.dump!(version.id)
      ])
    end

    assert {1, _} =
             Repo.delete_all(from v in FunctionalAnalysisVersion, where: v.id == ^version.id)

    refute Repo.get(FunctionalAnalysisVersion, version.id)
  end

  test "an unauthorized professional cannot retrieve version content" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Secreto"
      )

    {:ok, version} =
      ClinicalRecord.register_functional_analysis_version(
        professional,
        patient.id,
        target.id,
        draft.lock_version,
        "Nota secreta"
      )

    other = create_professional!()

    assert {:error, :unauthorized} =
             ClinicalRecord.get_functional_analysis_version(
               other,
               patient.id,
               target.id,
               version.id
             )
  end

  test "re-encrypts a legacy v1 draft body under the clinical-record key when registering" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(professional, patient.id, target.id, "x")

    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, legacy_body} = PatientVault.encrypt("Legacy plaintext body", patient_dek)

    legacy =
      draft
      |> Ecto.Changeset.change(encrypted_body: legacy_body, encryption_version: 1)
      |> Repo.update!()

    assert {:ok, version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               legacy.lock_version,
               "Legacy note"
             )

    assert version.encryption_version == 2

    assert {:ok, [listed]} =
             ClinicalRecord.list_functional_analysis_versions(professional, patient.id, target.id)

    assert listed.body == "Legacy plaintext body"
    assert listed.change_note == "Legacy note"

    assert {:ok, loaded} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               version.id
             )

    assert loaded.body == "Legacy plaintext body"
  end

  test "fails registration without consuming a sequence number when the draft cannot be decrypted" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(professional, patient.id, target.id, "x")

    corrupt =
      draft
      |> Ecto.Changeset.change(encrypted_body: "not-a-ciphertext", encryption_version: 1)
      |> Repo.update!()

    assert {:error, _reason} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               corrupt.lock_version,
               "Note"
             )

    assert Repo.aggregate(FunctionalAnalysisVersion, :count) == 0

    assert Repo.get!(Alethea.ClinicalRecord.TargetBehavior, target.id)
           |> Map.fetch!(:functional_analysis_version_sequence) == 0
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "functional-version-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Version"
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
