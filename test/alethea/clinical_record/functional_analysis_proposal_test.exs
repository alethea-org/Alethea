defmodule Alethea.ClinicalRecord.FunctionalAnalysisProposalTest do
  @moduledoc """
  Domain acceptance tests for applying reviewed AI functional analysis proposals
  to the mutable working draft (Issue #368, T1).

  Verifies:
  - Atomic acceptance into working draft only (no historical version writes).
  - Distinguishing draft absence (:no_draft) from integer baseline.
  - Fail-closed validation rejecting missing, nil, unconstrained, or malformed options.
  - Concurrency conflict detection on stale draft baseline.
  - Idempotent duplicate acceptance with the same baseline.
  - Verification of cited evidence liveness and legal deletion.
  - Fresh authorization and cross-patient isolation.
  """
  use Alethea.DataCase, async: false

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    FunctionalAnalysisContent,
    FunctionalAnalysisDraft,
    FunctionalAnalysisVersion,
    TargetBehavior,
    Tombstone
  }

  @valid_proposal_params %{
    "antecedents_distal" => "Historia de dificultades en el trabajo",
    "antecedents_immediate" => "Llegada al hogar tras jornada laboral",
    "organism_sleep" => "Duerme 5 horas por noche",
    "organism_pain_or_discomfort" => "Dolor cervical leve",
    "organism_hunger_or_nutrition" => "Sin apetito",
    "organism_learning_history" => "Refuerzo negativo previo",
    "response_physiological" => "Taquicardia",
    "response_cognitive" => "Pensamientos catastrofistas",
    "response_motor" => "Evitacion de interacciones",
    "consequences_short_term" => "Alivio inmediato de tension",
    "consequences_long_term" => "Aislamiento y deterioro relacional",
    "previous_notes" => "Notas previas intactas"
  }

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)

    {:ok, target_behavior} =
      ClinicalRecord.create_target_behavior(professional, patient.id, "Salir a caminar")

    %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    }
  end

  describe "apply_functional_analysis_ai_proposal/5 — strict fail-closed options validation (Issue #368)" do
    test "omitting :draft_baseline fails closed with {:error, :invalid_draft_baseline} and makes no writes",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:error, :invalid_draft_baseline} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: []
               )

      assert Repo.get_by(FunctionalAnalysisDraft, target_behavior_id: target_behavior.id) == nil
    end

    test "passing nil, :unconstrained, 0, or malformed :draft_baseline fails closed with {:error, :invalid_draft_baseline}",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      for invalid_baseline <- [nil, :unconstrained, 0, -1, "1", "no_draft", :none, :missing] do
        assert {:error, :invalid_draft_baseline} =
                 ClinicalRecord.apply_functional_analysis_ai_proposal(
                   professional,
                   patient.id,
                   target_behavior.id,
                   @valid_proposal_params,
                   draft_baseline: invalid_baseline,
                   cited_evidence_ids: []
                 )
      end

      assert Repo.get_by(FunctionalAnalysisDraft, target_behavior_id: target_behavior.id) == nil
    end

    test "omitting :cited_evidence_ids fails closed with {:error, :invalid_cited_evidence_ids} and makes no writes",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:error, :invalid_cited_evidence_ids} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft
               )

      assert Repo.get_by(FunctionalAnalysisDraft, target_behavior_id: target_behavior.id) == nil
    end

    test "passing nil, non-list, or malformed UUID in :cited_evidence_ids fails closed with {:error, :invalid_cited_evidence_ids}",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      for invalid_ids <- [nil, "not-a-list", MapSet.new(), ["not-a-uuid"], [123]] do
        assert {:error, :invalid_cited_evidence_ids} =
                 ClinicalRecord.apply_functional_analysis_ai_proposal(
                   professional,
                   patient.id,
                   target_behavior.id,
                   @valid_proposal_params,
                   draft_baseline: :no_draft,
                   cited_evidence_ids: invalid_ids
                 )
      end

      assert Repo.get_by(FunctionalAnalysisDraft, target_behavior_id: target_behavior.id) == nil
    end

    test "passing empty options list [] fails closed with {:error, :invalid_draft_baseline} and makes no writes",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:error, :invalid_draft_baseline} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 []
               )

      assert Repo.get_by(FunctionalAnalysisDraft, target_behavior_id: target_behavior.id) == nil
    end

    test "option aliases are rejected and fail closed",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      # expected_lock_version is rejected because draft_baseline is required
      assert {:error, :invalid_draft_baseline} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 expected_lock_version: :no_draft,
                 cited_evidence_ids: []
               )

      # evidence_ids is rejected because cited_evidence_ids is required
      assert {:error, :invalid_cited_evidence_ids} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 evidence_ids: []
               )
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — happy path and baseline matching" do
    test "applies entire proposal to an existing draft at baseline version and increments lock_version",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      # Seed initial draft at lock_version 1
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1}} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"antecedents_distal" => "Borrador inicial"}
               )

      assert {:ok, %FunctionalAnalysisDraft{lock_version: 2} = draft} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: 1,
                 cited_evidence_ids: []
               )

      assert draft.lock_version == 2

      # Verify decrypted content matches proposal
      assert {:ok, %FunctionalAnalysisContent{} = content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_distal == @valid_proposal_params["antecedents_distal"]
      assert content.consequences_long_term == @valid_proposal_params["consequences_long_term"]
      assert content.previous_notes == @valid_proposal_params["previous_notes"]
    end

    test "applies proposal when no draft exists using :no_draft baseline",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      # Ensure no draft exists initially
      assert {:ok, nil} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1} = draft} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )

      assert draft.lock_version == 1

      assert {:ok, %FunctionalAnalysisContent{} = content} =
               ClinicalRecord.get_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id
               )

      assert content.antecedents_immediate == @valid_proposal_params["antecedents_immediate"]
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — baseline concurrency checks" do
    test ":no_draft baseline rejects application if a draft was created concurrently",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      # Preview started when there was no draft (:no_draft baseline)
      # But before apply, another write created a draft
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1}} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"antecedents_distal" => "Borrador concurrente"}
               )

      # Must return conflict because baseline was :no_draft but draft exists
      assert {:error, :conflict} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — duplicate acceptance idempotency" do
    test "duplicate acceptance with same baseline does not increment lock_version or write again",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1}} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"antecedents_distal" => "Borrador inicial"}
               )

      # First apply with baseline 1 -> increments to 2
      assert {:ok, %FunctionalAnalysisDraft{id: draft_id, lock_version: 2}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: 1,
                 cited_evidence_ids: []
               )

      # Second apply with SAME baseline 1 and identical proposal
      assert {:ok, %FunctionalAnalysisDraft{id: ^draft_id, lock_version: 2}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: 1,
                 cited_evidence_ids: []
               )

      # Verify draft lock_version remains 2 (not 3)
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 2}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end

    test "duplicate acceptance with :no_draft baseline does not increment lock_version",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      # First apply from :no_draft creates draft at lock_version 1
      assert {:ok, %FunctionalAnalysisDraft{id: draft_id, lock_version: 1}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )

      # Second apply with same :no_draft baseline returns ok at lock_version 1
      assert {:ok, %FunctionalAnalysisDraft{id: ^draft_id, lock_version: 1}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — conflict detection" do
    test "returns {:error, :conflict} when baseline is stale and content does not match",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1}} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"antecedents_distal" => "Borrador inicial"}
               )

      # Draft is at 1, but baseline expects 2
      assert {:error, :conflict} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: 2,
                 cited_evidence_ids: []
               )
    end

    test "returns {:error, :conflict} when baseline expects an existing draft but none exists",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:error, :conflict} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: 1,
                 cited_evidence_ids: []
               )
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — cited evidence liveness" do
    test "succeeds when all cited evidence items are live",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      {:ok, ev1} = add_evidence!(professional, patient, target_behavior, "Evidencia 1")
      {:ok, ev2} = add_evidence!(professional, patient, target_behavior, "Evidencia 2")

      assert {:ok, %FunctionalAnalysisDraft{}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: [ev1.id, ev2.id],
                 draft_baseline: :no_draft
               )
    end

    test "returns {:error, :stale_cited_evidence} when a cited evidence does not exist",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      missing_id = Ecto.UUID.generate()

      assert {:error, :stale_cited_evidence} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: [missing_id],
                 draft_baseline: :no_draft
               )
    end

    test "returns {:error, :stale_cited_evidence} when a cited evidence belongs to another patient",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      other_patient = create_patient!(professional)

      {:ok, other_target} =
        ClinicalRecord.create_target_behavior(professional, other_patient.id, "Otra conducta")

      {:ok, other_ev} =
        add_evidence!(professional, other_patient, other_target, "Evidencia ajena")

      assert {:error, :stale_cited_evidence} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: [other_ev.id],
                 draft_baseline: :no_draft
               )
    end

    test "returns {:error, :stale_cited_evidence} when a cited evidence has a tombstone",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      {:ok, ev} = add_evidence!(professional, patient, target_behavior, "Evidencia eliminada")

      # Create tombstone for the evidence
      %Tombstone{}
      |> Tombstone.changeset(%{
        resource_type: "consultation_evidence",
        resource_id: ev.id,
        patient_id: patient.id,
        target_behavior_id: target_behavior.id,
        deleted_at: DateTime.utc_now(),
        deleted_by_id: professional.id,
        trigger: "manual"
      })
      |> Repo.insert!()

      assert {:error, :stale_cited_evidence} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: [ev.id],
                 draft_baseline: :no_draft
               )
    end

    test "succeeds when a deleted citation was removed by the clinician from cited_evidence_ids",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      {:ok, live_ev} = add_evidence!(professional, patient, target_behavior, "Evidencia viva")

      {:ok, deleted_ev} =
        add_evidence!(professional, patient, target_behavior, "Evidencia a borrar")

      # Tombstone the deleted evidence
      %Tombstone{}
      |> Tombstone.changeset(%{
        resource_type: "consultation_evidence",
        resource_id: deleted_ev.id,
        patient_id: patient.id,
        target_behavior_id: target_behavior.id,
        deleted_at: DateTime.utc_now(),
        deleted_by_id: professional.id,
        trigger: "manual"
      })
      |> Repo.insert!()

      # Clinician removed deleted_ev from the proposal, so only live_ev is passed
      assert {:ok, %FunctionalAnalysisDraft{}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: [live_ev.id],
                 draft_baseline: :no_draft
               )
    end

    test "succeeds when cited_evidence_ids is empty list []",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:ok, %FunctionalAnalysisDraft{}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 cited_evidence_ids: [],
                 draft_baseline: :no_draft
               )
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — draft legal deletion" do
    test "returns {:error, :legally_deleted} when the draft has a tombstone and does not write",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      # Create draft tombstone
      %Tombstone{}
      |> Tombstone.changeset(%{
        resource_type: "functional_analysis_draft",
        resource_id: Ecto.UUID.generate(),
        patient_id: patient.id,
        target_behavior_id: target_behavior.id,
        deleted_at: DateTime.utc_now(),
        deleted_by_id: professional.id,
        trigger: "manual"
      })
      |> Repo.insert!()

      assert {:error, :legally_deleted} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )

      # Ensure no draft was created
      assert Repo.get_by(FunctionalAnalysisDraft, target_behavior_id: target_behavior.id) == nil
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — authorization and ownership" do
    test "returns {:error, :unauthorized} for a professional not responsible for the patient",
         %{patient: patient, target_behavior: target_behavior} do
      other_professional = create_professional!()

      assert {:error, :unauthorized} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 other_professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )
    end

    test "returns {:error, :not_found} for cross-patient target_behavior_id",
         %{professional: professional, patient: patient} do
      other_patient = create_patient!(professional)

      {:ok, other_target} =
        ClinicalRecord.create_target_behavior(professional, other_patient.id, "Otra conducta")

      # Attempt to apply using patient.id with other_target.id
      assert {:error, :not_found} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 other_target.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — historical isolation" do
    test "persists ONLY to FunctionalAnalysisDraft and NEVER writes to FunctionalAnalysisVersion",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      initial_version_count = Repo.aggregate(FunctionalAnalysisVersion, :count)

      assert {:ok, %FunctionalAnalysisDraft{}} =
               ClinicalRecord.apply_functional_analysis_ai_proposal(
                 professional,
                 patient.id,
                 target_behavior.id,
                 @valid_proposal_params,
                 draft_baseline: :no_draft,
                 cited_evidence_ids: []
               )

      # Strictly 0 new version rows
      assert Repo.aggregate(FunctionalAnalysisVersion, :count) == initial_version_count

      # Target behavior sequence must NOT increment
      refreshed_target = Repo.get!(TargetBehavior, target_behavior.id)
      assert refreshed_target.functional_analysis_version_sequence == 0
    end
  end

  describe "apply_functional_analysis_ai_proposal/5 — concurrent execution and deterministic serialization" do
    test "concurrent apply calls from :no_draft serialize cleanly without double-creation",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      params1 = Map.put(@valid_proposal_params, "antecedents_distal", "Propuesta A")
      params2 = Map.put(@valid_proposal_params, "antecedents_distal", "Propuesta B")

      task1 =
        Task.async(fn ->
          ClinicalRecord.apply_functional_analysis_ai_proposal(
            professional,
            patient.id,
            target_behavior.id,
            params1,
            draft_baseline: :no_draft,
            cited_evidence_ids: []
          )
        end)

      task2 =
        Task.async(fn ->
          ClinicalRecord.apply_functional_analysis_ai_proposal(
            professional,
            patient.id,
            target_behavior.id,
            params2,
            draft_baseline: :no_draft,
            cited_evidence_ids: []
          )
        end)

      results = Task.await_many([task1, task2], 5000)

      successes =
        Enum.filter(results, &match?({:ok, %FunctionalAnalysisDraft{lock_version: 1}}, &1))

      conflicts = Enum.filter(results, &(&1 == {:error, :conflict}))

      assert length(successes) == 1
      assert length(conflicts) == 1

      # Final draft in DB is at lock_version 1
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end

    test "concurrent apply calls against an existing draft serialize: one increments version, one conflicts",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      assert {:ok, %FunctionalAnalysisDraft{lock_version: 1}} =
               ClinicalRecord.upsert_functional_analysis_content(
                 professional,
                 patient.id,
                 target_behavior.id,
                 %{"antecedents_distal" => "Borrador inicial"}
               )

      params1 = Map.put(@valid_proposal_params, "antecedents_distal", "Modificacion A")
      params2 = Map.put(@valid_proposal_params, "antecedents_distal", "Modificacion B")

      task1 =
        Task.async(fn ->
          ClinicalRecord.apply_functional_analysis_ai_proposal(
            professional,
            patient.id,
            target_behavior.id,
            params1,
            draft_baseline: 1,
            cited_evidence_ids: []
          )
        end)

      task2 =
        Task.async(fn ->
          ClinicalRecord.apply_functional_analysis_ai_proposal(
            professional,
            patient.id,
            target_behavior.id,
            params2,
            draft_baseline: 1,
            cited_evidence_ids: []
          )
        end)

      results = Task.await_many([task1, task2], 5000)

      successes =
        Enum.filter(results, &match?({:ok, %FunctionalAnalysisDraft{lock_version: 2}}, &1))

      conflicts = Enum.filter(results, &(&1 == {:error, :conflict}))

      assert length(successes) == 1
      assert length(conflicts) == 1

      assert {:ok, %FunctionalAnalysisDraft{lock_version: 2}} =
               ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient.id,
                 target_behavior.id
               )
    end
  end

  # Helpers

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "proposal-test-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Proposal Test"
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

  defp add_evidence!(professional, patient, target_behavior, text) do
    {:ok, note} = ClinicalRecord.create_clinical_note(professional, patient.id, text)

    {:ok, evidence} =
      ClinicalRecord.cite_evidence_source(
        professional,
        patient.id,
        target_behavior.id,
        %{
          source_kind: "clinical_note",
          source_id: note.id,
          excerpt: text
        }
      )

    {:ok, evidence}
  end
end
