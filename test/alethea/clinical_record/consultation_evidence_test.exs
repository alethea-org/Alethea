defmodule Alethea.ClinicalRecord.ConsultationEvidenceTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.ConsultationEvidence`
  (sdd/alethea/issue-195-clinical-review-workbench, PR1a task 1.1). Mirrors
  `Alethea.ClinicalRecord.ClinicalNote` — create-only: no update changeset,
  `timestamps/1` omits `updated_at`. DB-level immutability enforcement (the
  `BEFORE UPDATE` trigger) is proven separately below (task 1.3), since it
  needs a real DB round-trip with FK rows.
  """
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.ConsultationEvidence

  @valid_attrs %{
    source_kind: "clinical_note",
    source_id: Ecto.UUID.generate(),
    encrypted_excerpt: <<1, 2, 3>>,
    occurred_at: DateTime.utc_now(),
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate(),
    target_behavior_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields (clinical_note source)" do
      changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :source_kind) == "clinical_note"
      assert get_change(changeset, :source_id) == @valid_attrs.source_id
      assert get_change(changeset, :encrypted_excerpt) == <<1, 2, 3>>
      assert get_change(changeset, :patient_id) == @valid_attrs.patient_id
      assert get_change(changeset, :professional_id) == @valid_attrs.professional_id
      assert get_change(changeset, :target_behavior_id) == @valid_attrs.target_behavior_id
    end

    test "is valid with a message source (triangulation)" do
      attrs = %{@valid_attrs | source_kind: "message", source_id: Ecto.UUID.generate()}

      changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :source_kind) == "message"
    end

    test "encryption_version defaults to 1 when not cast" do
      changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, @valid_attrs)

      assert changeset.valid?

      assert %ConsultationEvidence{encryption_version: 1} =
               Ecto.Changeset.apply_changes(changeset)
    end
  end

  describe "changeset/2 — source_kind vocabulary" do
    test "rejects a source_kind outside clinical_note/message" do
      attrs = %{@valid_attrs | source_kind: "diagnosis"}

      changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).source_kind
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects a missing source_kind" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :source_kind)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source_kind
    end

    test "rejects a missing source_id" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :source_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source_id
    end

    test "rejects a missing encrypted_excerpt" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :encrypted_excerpt)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_excerpt
    end

    test "rejects a missing occurred_at" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :occurred_at)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).occurred_at
    end

    test "rejects a missing patient_id" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :patient_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "rejects a missing professional_id" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :professional_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).professional_id
    end

    test "rejects a missing target_behavior_id" do
      changeset =
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.delete(@valid_attrs, :target_behavior_id)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_behavior_id
    end
  end

  describe "no update path exists (structural immutability)" do
    test "the module exports no update_changeset/2 function" do
      refute function_exported?(ConsultationEvidence, :update_changeset, 2)
    end
  end

  describe "changeset/2 — session_transcript audio markers (AD9, GitHub #328)" do
    @transcript_attrs %{
      source_kind: "session_transcript",
      source_id: Ecto.UUID.generate(),
      encrypted_excerpt: <<1, 2, 3>>,
      occurred_at: DateTime.utc_now(),
      patient_id: Ecto.UUID.generate(),
      professional_id: Ecto.UUID.generate(),
      target_behavior_id: Ecto.UUID.generate(),
      speaker: "patient",
      audio_start_seconds: 860.0,
      audio_end_seconds: 910.0
    }

    test "is accepted when all three markers are present" do
      changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, @transcript_attrs)

      assert changeset.valid?
      assert get_change(changeset, :speaker) == "patient"
      assert get_change(changeset, :audio_start_seconds) == 860.0
      assert get_change(changeset, :audio_end_seconds) == 910.0
    end

    test "rejects a session_transcript row missing any one marker (table-driven)" do
      for missing_key <- [:speaker, :audio_start_seconds, :audio_end_seconds] do
        attrs = Map.put(@transcript_attrs, missing_key, nil)
        changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, attrs)

        refute changeset.valid?, "expected invalid when #{missing_key} is nil"
        assert "can't be blank" in errors_on(changeset)[missing_key]
      end
    end

    test "rejects a speaker outside SessionTranscriptContent.speakers()" do
      attrs = %{@transcript_attrs | speaker: "psychologist"}
      changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).speaker
    end

    test "legacy kinds (clinical_note, message) accept nil markers (table-driven)" do
      for source_kind <- ["clinical_note", "message"] do
        attrs = %{@valid_attrs | source_kind: source_kind}
        changeset = ConsultationEvidence.changeset(%ConsultationEvidence{}, attrs)

        assert changeset.valid?, "expected #{source_kind} valid with nil markers"
      end
    end
  end

  describe "database-level source_kind CHECK constraint (task 1.2, AD1)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, "Salir a caminar")

      %{professional: professional, patient: patient, target_behavior: target_behavior}
    end

    test "an unknown source_kind raises the CHECK, a legacy clinical_note row with NULL markers is accepted",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      insert = fn source_kind ->
        Repo.query(
          """
          INSERT INTO consultation_evidences
            (id, source_kind, source_id, encrypted_excerpt, encryption_version, occurred_at,
             speaker, audio_start_seconds, audio_end_seconds,
             patient_id, professional_id, target_behavior_id, inserted_at)
          VALUES
            ($1::text::uuid, $2, $3::text::uuid, $4, 1, $5, NULL, NULL, NULL,
             $6::text::uuid, $7::text::uuid, $8::text::uuid, $9)
          """,
          [
            Ecto.UUID.generate(),
            source_kind,
            Ecto.UUID.generate(),
            <<9, 9, 9>>,
            DateTime.utc_now(),
            patient.id,
            professional.id,
            target_behavior.id,
            DateTime.utc_now()
          ]
        )
      end

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               insert.("clinician_observation")

      assert {:ok, _result} = insert.("clinical_note")
    end
  end

  describe "database-level immutability (task 1.3)" do
    setup do
      professional = create_professional!()
      patient = create_patient!(professional)

      {:ok, target_behavior} =
        ClinicalRecord.create_target_behavior(professional, patient.id, "Salir a caminar")

      {:ok, evidence} =
        %ConsultationEvidence{}
        |> ConsultationEvidence.changeset(%{
          source_kind: "clinical_note",
          source_id: Ecto.UUID.generate(),
          encrypted_excerpt: <<9, 9, 9>>,
          occurred_at: DateTime.utc_now(),
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: target_behavior.id
        })
        |> Repo.insert()

      %{evidence: evidence}
    end

    test "a raw UPDATE against the excerpt column raises via Postgrex, not Ecto", %{
      evidence: evidence
    } do
      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE consultation_evidences SET encryption_version = 2 WHERE id = $1::text::uuid",
                 [evidence.id]
               )
    end
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "consultation-evidence-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Consultation Evidence"
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
