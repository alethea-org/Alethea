defmodule Alethea.ClinicalRecord.ClinicalRecordDekWritesTest do
  @moduledoc """
  Clinical-record writes use the destroyable key (security-audit-run-1, S5;
  AD1, sdd/clinical-record-retention): new `ClinicalNote`, `TargetBehavior`
  and `AIProposal` rows are encrypted under the `"patient_clinical_record"`
  DEK and stamped `encryption_version: 2`, so terminal cryptographic
  erasure of that key leaves no surviving journaling key able to decrypt a
  retained copy of their ciphertext. Legacy `encryption_version: 1` rows
  (shared patient DEK) keep reading correctly.
  """
  # async: false — the AI proposal worker test swaps nothing global, but the
  # RAG indexer reads the global `:ai_embeddings` adapter slot.
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{AIProposal, ClinicalNote, Retention, TargetBehavior}
  alias Alethea.ClinicalRecord.Rag.{Chunk, Indexer}
  alias Alethea.Encryption.PatientVault
  alias AletheaJobs.AIProposalWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)

    %{professional: professional, patient: patient, kek: kek, patient_dek: patient_dek}
  end

  describe "create_clinical_note/4 writes under the clinical-record DEK" do
    test "stamps encryption_version 2; ciphertext decrypts only under the CR DEK", ctx do
      assert {:ok, %ClinicalNote{} = note} =
               ClinicalRecord.create_clinical_note(ctx.professional, ctx.patient.id, "Nota v2")

      persisted = Repo.get!(ClinicalNote, note.id)
      assert persisted.encryption_version == 2

      {:ok, cr_dek} = Accounts.load_clinical_record_dek(ctx.patient, ctx.kek)
      assert {:ok, "Nota v2"} = PatientVault.decrypt(persisted.encrypted_body, cr_dek)
      assert {:error, _} = PatientVault.decrypt(persisted.encrypted_body, ctx.patient_dek)

      assert {:ok, [%ClinicalNote{body: "Nota v2"}]} =
               ClinicalRecord.list_clinical_notes(ctx.professional, ctx.patient.id)

      assert {:ok, %{entries: [%ClinicalNote{body: "Nota v2"}]}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, [])
    end

    test "legal deletion destroys the CR key; the captured ciphertext is not decryptable by the surviving patient DEK",
         ctx do
      {:ok, note} =
        ClinicalRecord.create_clinical_note(ctx.professional, ctx.patient.id, "Borrar")

      captured = Repo.get!(ClinicalNote, note.id).encrypted_body

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"clinical_note", note.id},
                 actor: ctx.professional,
                 trigger: "manual"
               )

      refute Repo.get_by(EncryptionKey,
               patient_id: ctx.patient.id,
               type: "patient_clinical_record"
             )

      assert {:ok, surviving_dek} = Accounts.load_patient_dek(ctx.patient, ctx.kek)
      assert surviving_dek == ctx.patient_dek
      assert {:error, _} = PatientVault.decrypt(captured, surviving_dek)
    end

    test "the RAG chunk of a new note follows the source to encryption_version 2", ctx do
      {:ok, note} =
        ClinicalRecord.create_clinical_note(ctx.professional, ctx.patient.id, "Avances notables.")

      assert :ok =
               Indexer.index_event(%{
                 "event" => "clinical_note_created",
                 "resource_type" => "clinical_note",
                 "resource_id" => note.id,
                 "patient_id" => ctx.patient.id,
                 "professional_id" => ctx.professional.id
               })

      assert [chunk] =
               Chunk |> Repo.all() |> Enum.filter(&(&1.source_resource_id == note.id))

      assert chunk.encryption_version == 2
      {:ok, cr_dek} = Accounts.load_clinical_record_dek(ctx.patient, ctx.kek)
      assert {:ok, "Avances notables."} = PatientVault.decrypt(chunk.encrypted_content, cr_dek)
      assert {:error, _} = PatientVault.decrypt(chunk.encrypted_content, ctx.patient_dek)
    end
  end

  describe "create_target_behavior/3 writes under the clinical-record DEK" do
    test "stamps encryption_version 2; ciphertext decrypts only under the CR DEK", ctx do
      assert {:ok, %TargetBehavior{} = target_behavior} =
               ClinicalRecord.create_target_behavior(ctx.professional, ctx.patient.id, "Caminar")

      persisted = Repo.get!(TargetBehavior, target_behavior.id)
      assert persisted.encryption_version == 2

      {:ok, cr_dek} = Accounts.load_clinical_record_dek(ctx.patient, ctx.kek)
      assert {:ok, "Caminar"} = PatientVault.decrypt(persisted.encrypted_description, cr_dek)
      assert {:error, _} = PatientVault.decrypt(persisted.encrypted_description, ctx.patient_dek)

      assert {:ok, [%{id: id, description: "Caminar"}]} =
               ClinicalRecord.list_target_behaviors(ctx.professional, ctx.patient.id)

      assert id == target_behavior.id

      assert {:ok, %TargetBehavior{description: "Caminar"}} =
               ClinicalRecord.get_target_behavior(
                 ctx.professional,
                 ctx.patient.id,
                 target_behavior.id
               )
    end

    test "legal deletion destroys the CR key; the captured ciphertext is not decryptable by the surviving patient DEK",
         ctx do
      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(ctx.professional, ctx.patient.id, "Borrar")

      captured = Repo.get!(TargetBehavior, target_behavior.id).encrypted_description

      assert {:ok, _tombstone} =
               Retention.legally_delete_record({"target_behavior", target_behavior.id},
                 actor: ctx.professional,
                 trigger: "manual"
               )

      refute Repo.get_by(EncryptionKey,
               patient_id: ctx.patient.id,
               type: "patient_clinical_record"
             )

      assert {:ok, surviving_dek} = Accounts.load_patient_dek(ctx.patient, ctx.kek)
      assert {:error, _} = PatientVault.decrypt(captured, surviving_dek)
    end
  end

  describe "AIProposalWorker writes under the clinical-record DEK" do
    test "new proposals are encryption_version 2 in both encrypted columns", ctx do
      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(ctx.professional, ctx.patient.id, "Conducta")

      expect(Alethea.AI.PatternProposalChainMock, :run, fn _input ->
        {:ok, %{proposals: ["Podria existir un patron"]}}
      end)

      assert :ok =
               perform_job(AIProposalWorker, %{
                 "professional_id" => ctx.professional.id,
                 "patient_id" => ctx.patient.id,
                 "target_behavior_id" => target_behavior.id
               })

      assert [proposal] = Repo.all(AIProposal)
      assert proposal.encryption_version == 2

      {:ok, cr_dek} = Accounts.load_clinical_record_dek(ctx.patient, ctx.kek)

      for ciphertext <- [proposal.encrypted_text, proposal.encrypted_original_text] do
        assert {:ok, "Podria existir un patron"} = PatientVault.decrypt(ciphertext, cr_dek)
        assert {:error, _} = PatientVault.decrypt(ciphertext, ctx.patient_dek)
      end

      assert {:ok, timeline} =
               ClinicalRecord.review_timeline(
                 ctx.professional,
                 ctx.patient.id,
                 target_behavior.id
               )

      assert Enum.any?(timeline, &(&1.text == "Podria existir un patron"))
    end
  end

  describe "reads never provision the clinical-record DEK" do
    test "listing notes and target behaviors of a patient without a CR key creates none", ctx do
      cr_keys = fn ->
        Repo.aggregate(
          from(k in EncryptionKey,
            where: k.patient_id == ^ctx.patient.id and k.type == "patient_clinical_record"
          ),
          :count
        )
      end

      assert cr_keys.() == 0
      assert {:ok, []} = ClinicalRecord.list_clinical_notes(ctx.professional, ctx.patient.id)
      assert {:ok, []} = ClinicalRecord.list_target_behaviors(ctx.professional, ctx.patient.id)

      assert {:ok, %{entries: []}} =
               ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, [])

      assert cr_keys.() == 0
    end
  end

  describe "legacy encryption_version 1 rows keep reading" do
    test "v1 notes and target behaviors decrypt under the shared patient DEK alongside v2 rows",
         ctx do
      {:ok, note_ct} = PatientVault.encrypt("Nota legado", ctx.patient_dek)
      {:ok, tb_ct} = PatientVault.encrypt("Conducta legado", ctx.patient_dek)

      legacy_note =
        %ClinicalNote{}
        |> ClinicalNote.changeset(%{
          encrypted_body: note_ct,
          encryption_version: 1,
          patient_id: ctx.patient.id,
          professional_id: ctx.professional.id
        })
        |> Repo.insert!()

      legacy_tb =
        %TargetBehavior{}
        |> TargetBehavior.changeset(%{
          encrypted_description: tb_ct,
          encryption_version: 1,
          patient_id: ctx.patient.id,
          professional_id: ctx.professional.id
        })
        |> Repo.insert!()

      {:ok, _} = ClinicalRecord.create_clinical_note(ctx.professional, ctx.patient.id, "Nota v2")

      {:ok, _} =
        ClinicalRecord.create_target_behavior(ctx.professional, ctx.patient.id, "Conducta v2")

      {:ok, notes} = ClinicalRecord.list_clinical_notes(ctx.professional, ctx.patient.id)
      assert notes |> Enum.map(& &1.body) |> Enum.sort() == ["Nota legado", "Nota v2"]

      {:ok, %{entries: page}} =
        ClinicalRecord.list_clinical_notes_page(ctx.professional, ctx.patient.id, [])

      assert page |> Enum.map(& &1.body) |> Enum.sort() == ["Nota legado", "Nota v2"]

      {:ok, behaviors} = ClinicalRecord.list_target_behaviors(ctx.professional, ctx.patient.id)

      assert behaviors |> Enum.map(& &1.description) |> Enum.sort() ==
               ["Conducta legado", "Conducta v2"]

      assert {:ok, %TargetBehavior{description: "Conducta legado"}} =
               ClinicalRecord.get_target_behavior(ctx.professional, ctx.patient.id, legacy_tb.id)

      assert Repo.get!(ClinicalNote, legacy_note.id).encryption_version == 1
    end

    test "editing a legacy v1 proposal moves the whole row to the CR DEK at v2", ctx do
      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(ctx.professional, ctx.patient.id, "Conducta")

      {:ok, ciphertext} = PatientVault.encrypt("Original legado", ctx.patient_dek)

      legacy =
        %AIProposal{}
        |> AIProposal.changeset(%{
          encrypted_original_text: ciphertext,
          encrypted_text: ciphertext,
          encryption_version: 1,
          model_version: "test-model",
          occurred_at: DateTime.utc_now(),
          patient_id: ctx.patient.id,
          professional_id: ctx.professional.id,
          target_behavior_id: target_behavior.id
        })
        |> Repo.insert!()

      assert {:ok, edited} =
               ClinicalRecord.edit_ai_proposal(
                 ctx.professional,
                 ctx.patient.id,
                 legacy.id,
                 "Editado"
               )

      {:ok, cr_dek} = Accounts.load_clinical_record_dek(ctx.patient, ctx.kek)
      persisted = Repo.get!(AIProposal, legacy.id)

      assert persisted.encryption_version == 2
      assert persisted.status == "edited"
      assert edited.encryption_version == 2
      assert {:ok, "Editado"} = PatientVault.decrypt(persisted.encrypted_text, cr_dek)

      # Same original plaintext, re-encrypted under the destroyable key.
      assert {:ok, "Original legado"} =
               PatientVault.decrypt(persisted.encrypted_original_text, cr_dek)

      assert {:error, _} = PatientVault.decrypt(persisted.encrypted_text, ctx.patient_dek)

      assert {:error, _} =
               PatientVault.decrypt(persisted.encrypted_original_text, ctx.patient_dek)
    end

    test "editing a v2 proposal stays v2 under the CR DEK", ctx do
      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(ctx.professional, ctx.patient.id, "Conducta")

      {:ok, cr_dek} = Accounts.ensure_clinical_record_dek(ctx.patient, ctx.kek)
      {:ok, ciphertext} = PatientVault.encrypt("Original v2", cr_dek)

      proposal =
        %AIProposal{}
        |> AIProposal.changeset(%{
          encrypted_original_text: ciphertext,
          encrypted_text: ciphertext,
          encryption_version: 2,
          model_version: "test-model",
          occurred_at: DateTime.utc_now(),
          patient_id: ctx.patient.id,
          professional_id: ctx.professional.id,
          target_behavior_id: target_behavior.id
        })
        |> Repo.insert!()

      assert {:ok, edited} =
               ClinicalRecord.edit_ai_proposal(
                 ctx.professional,
                 ctx.patient.id,
                 proposal.id,
                 "Editado v2"
               )

      assert edited.encryption_version == 2
      assert {:ok, "Editado v2"} = PatientVault.decrypt(edited.encrypted_text, cr_dek)
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "cr-dek-writes-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. CR DEK"
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
