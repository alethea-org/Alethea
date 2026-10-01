defmodule Alethea.ClinicalRecord.FunctionalAnalysisVersionTest do
  use Alethea.DataCase, async: false

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.FunctionalAnalysisVersion
  alias Alethea.ClinicalRecord.FunctionalAnalysisDraft
  alias Alethea.ClinicalRecord.FunctionalAnalysisContent
  alias Alethea.ClinicalRecord.Retention
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

  test "captures precise encrypted citation baseline at registration and redacts virtual plaintext in Inspect" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft1} =
      ClinicalRecord.upsert_functional_analysis_draft(professional, patient.id, target.id, "V1")

    # Baseline with 0 live citations should be empty list
    assert {:ok, v1} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft1.lock_version,
               "First version with no citations"
             )

    assert is_binary(v1.encrypted_cited_evidence_baseline)

    assert {:ok, loaded_v1} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               v1.id
             )

    assert loaded_v1.cited_evidence_baseline_ids == []

    # Add 2 consultation evidences
    e1 = add_evidence!(professional, patient, target, "Cita 1")
    e2 = add_evidence!(professional, patient, target, "Cita 2")

    {:ok, draft2} =
      ClinicalRecord.upsert_functional_analysis_draft(professional, patient.id, target.id, "V2")

    assert {:ok, v2} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft2.lock_version,
               "Second version with 2 citations"
             )

    # Ciphertext opacity: binary ciphertext, never plaintext UUID
    assert is_binary(v2.encrypted_cited_evidence_baseline)
    refute v2.encrypted_cited_evidence_baseline =~ e1.id
    refute v2.encrypted_cited_evidence_baseline =~ e2.id

    # Audit log and outbox never leak clinical citation plaintext or UUIDs
    audit = Repo.get_by!(AuditLog, resource_id: v2.id)
    refute inspect(audit.details) =~ e1.id
    refute inspect(audit.details) =~ e2.id

    job = Enum.find(Repo.all(Job), &(&1.args["resource_id"] == v2.id))
    assert job
    refute inspect(job.args) =~ e1.id
    refute inspect(job.args) =~ e2.id

    # Authorized read/list exposes decrypted baseline
    assert {:ok, loaded_v2} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               v2.id
             )

    assert Enum.sort(loaded_v2.cited_evidence_baseline_ids) == Enum.sort([e1.id, e2.id])

    # Inspect redacts virtual plaintext ID field
    refute inspect(loaded_v2) =~ e1.id
    refute inspect(loaded_v2) =~ e2.id

    assert {:ok, [list_v1, list_v2]} =
             ClinicalRecord.list_functional_analysis_versions(professional, patient.id, target.id)

    assert list_v1.cited_evidence_baseline_ids == []
    assert Enum.sort(list_v2.cited_evidence_baseline_ids) == Enum.sort([e1.id, e2.id])
  end

  test "snapshots only currently live citation identity and excludes legally removed or cross-patient evidence" do
    professional = create_professional!()
    patient1 = create_patient!(professional)
    patient2 = create_patient!(professional)

    {:ok, target1} = ClinicalRecord.create_target_behavior(professional, patient1.id, "Target 1")
    {:ok, target2} = ClinicalRecord.create_target_behavior(professional, patient2.id, "Target 2")

    e1 = add_evidence!(professional, patient1, target1, "Evidence 1")
    e2 = add_evidence!(professional, patient1, target1, "Evidence 2")
    _other_evidence = add_evidence!(professional, patient2, target2, "Other patient evidence")

    # Legally remove e1 before registration
    assert {:ok, _tombstone} =
             Retention.legally_delete_record(
               {"consultation_evidence", e1.id},
               actor: professional,
               trigger: "manual"
             )

    e3 = add_evidence!(professional, patient1, target1, "Evidence 3")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient1.id,
        target1.id,
        "Draft content"
      )

    assert {:ok, version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient1.id,
               target1.id,
               draft.lock_version,
               "Version sign-off"
             )

    assert {:ok, loaded} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient1.id,
               target1.id,
               version.id
             )

    # Legally removed e1 is absent; cross-patient evidence is absent; only live e2 and e3 are present
    assert Enum.sort(loaded.cited_evidence_baseline_ids) == Enum.sort([e2.id, e3.id])
    refute e1.id in loaded.cited_evidence_baseline_ids
  end

  test "existing historical version rows without baseline decrypt with nil unknown baseline" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Draft text"
      )

    assert {:ok, version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft.lock_version,
               "Note"
             )

    # Simulate legacy row by setting encrypted_cited_evidence_baseline to nil
    # Note: we temporarily disable the no_update trigger for this simulation if needed,
    # or test nil directly.
    Repo.query!(
      "ALTER TABLE functional_analysis_versions DISABLE TRIGGER functional_analysis_versions_no_update"
    )

    Repo.query!(
      "UPDATE functional_analysis_versions SET encrypted_cited_evidence_baseline = NULL WHERE id = $1",
      [Ecto.UUID.dump!(version.id)]
    )

    Repo.query!(
      "ALTER TABLE functional_analysis_versions ENABLE TRIGGER functional_analysis_versions_no_update"
    )

    assert {:ok, loaded} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               version.id
             )

    assert is_nil(loaded.cited_evidence_baseline_ids)

    assert {:ok, [listed]} =
             ClinicalRecord.list_functional_analysis_versions(professional, patient.id, target.id)

    assert is_nil(listed.cited_evidence_baseline_ids)
  end

  test "fails closed when ciphertext is corrupted rather than inventing a baseline" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Draft text"
      )

    assert {:ok, version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft.lock_version,
               "Note"
             )

    Repo.query!(
      "ALTER TABLE functional_analysis_versions DISABLE TRIGGER functional_analysis_versions_no_update"
    )

    Repo.query!(
      "UPDATE functional_analysis_versions SET encrypted_cited_evidence_baseline = $1 WHERE id = $2",
      ["corrupted-ciphertext-not-valid", Ecto.UUID.dump!(version.id)]
    )

    Repo.query!(
      "ALTER TABLE functional_analysis_versions ENABLE TRIGGER functional_analysis_versions_no_update"
    )

    assert {:error, _reason} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               version.id
             )

    assert {:error, _reason} =
             ClinicalRecord.list_functional_analysis_versions(
               professional,
               patient.id,
               target.id
             )

    # Valid ciphertext of malformed payload (not a list of string UUIDs) also fails closed
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_clinical_record_dek(patient, kek)
    {:ok, bad_payload_ciphertext} = PatientVault.encrypt(~s({"not": "a list"}), dek)

    Repo.query!(
      "ALTER TABLE functional_analysis_versions DISABLE TRIGGER functional_analysis_versions_no_update"
    )

    Repo.query!(
      "UPDATE functional_analysis_versions SET encrypted_cited_evidence_baseline = $1 WHERE id = $2",
      [bad_payload_ciphertext, Ecto.UUID.dump!(version.id)]
    )

    Repo.query!(
      "ALTER TABLE functional_analysis_versions ENABLE TRIGGER functional_analysis_versions_no_update"
    )

    assert {:error, :invalid_baseline} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               version.id
             )

    assert {:error, :invalid_baseline} =
             ClinicalRecord.list_functional_analysis_versions(
               professional,
               patient.id,
               target.id
             )

    # Valid ciphertext of non-UUID strings in list also fails closed
    {:ok, bad_uuid_ciphertext} = PatientVault.encrypt(~s(["not-a-valid-uuid"]), dek)

    Repo.query!(
      "ALTER TABLE functional_analysis_versions DISABLE TRIGGER functional_analysis_versions_no_update"
    )

    Repo.query!(
      "UPDATE functional_analysis_versions SET encrypted_cited_evidence_baseline = $1 WHERE id = $2",
      [bad_uuid_ciphertext, Ecto.UUID.dump!(version.id)]
    )

    Repo.query!(
      "ALTER TABLE functional_analysis_versions ENABLE TRIGGER functional_analysis_versions_no_update"
    )

    assert {:error, :invalid_baseline} =
             ClinicalRecord.get_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               version.id
             )

    assert {:error, :invalid_baseline} =
             ClinicalRecord.list_functional_analysis_versions(
               professional,
               patient.id,
               target.id
             )
  end

  test "unauthorized professional cannot access version baseline" do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, target} = ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta")
    _evidence = add_evidence!(professional, patient, target, "Cita confidencial")

    {:ok, draft} =
      ClinicalRecord.upsert_functional_analysis_draft(
        professional,
        patient.id,
        target.id,
        "Contenido"
      )

    assert {:ok, version} =
             ClinicalRecord.register_functional_analysis_version(
               professional,
               patient.id,
               target.id,
               draft.lock_version,
               "Nota"
             )

    other = create_professional!()

    assert {:error, :unauthorized} =
             ClinicalRecord.get_functional_analysis_version(
               other,
               patient.id,
               target.id,
               version.id
             )

    assert {:error, :unauthorized} =
             ClinicalRecord.list_functional_analysis_versions(
               other,
               patient.id,
               target.id
             )
  end

  defp add_evidence!(professional, patient, target, text) do
    {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, text)

    {:ok, evidence} =
      ClinicalRecord.cite_evidence_source(
        professional,
        patient.id,
        target.id,
        %{
          source_kind: "clinical_note",
          source_id: note.id,
          excerpt: text
        }
      )

    evidence
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
