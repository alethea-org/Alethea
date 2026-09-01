defmodule AletheaJobs.AIProposalWorkerTest do
  @moduledoc """
  RED-phase specs for `AletheaJobs.AIProposalWorker`
  (sdd/alethea/issue-195-clinical-review-workbench, GitHub #195, PR4,
  task 6.2).

  AI pipeline regression test (repo CLAUDE.md mandate: "Every AI pipeline
  change must include a sentiment regression test"): the "sanitizes PII
  before every chain call" test below asserts the chain never receives
  raw PII from a cited evidence excerpt — the sanitizer regression
  equivalent for a chain that classifies functional-analysis patterns
  rather than sentiment.

  Structural safety test: `AIProposalWorker never references a
  confirm/accept/note-write function` is a static source-scan (grep-style)
  assertion, not a mock-based behavioral test — chosen because the
  acceptance criterion is about the absence of a *code path*, which a
  purely behavioral test could pass by accident (e.g. if a reachable
  branch calling `create_clinical_note/3` were simply never hit by the
  test's inputs). Reading the compiled module's source guarantees the
  reference cannot exist anywhere in the file, reachable or not.
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{AIProposal, ConsultationEvidence}
  alias AletheaJobs.AIProposalWorker

  @password "supersecret12"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)

    {:ok, target_behavior} =
      ClinicalRecord.create_target_behavior(professional, patient.id, "Conducta objetivo")

    %{professional: professional, patient: patient, target_behavior: target_behavior}
  end

  describe "perform/1 — canonical success" do
    test "sanitizes PII before every chain call, then inserts pending proposals and broadcasts ready",
         %{professional: professional, patient: patient, target_behavior: target_behavior} do
      insert_evidence!(
        professional,
        patient,
        target_behavior,
        "clinical_note",
        Ecto.UUID.generate(),
        "Contactar a juan.perez@example.com sobre el episodio"
      )

      Phoenix.PubSub.subscribe(Alethea.PubSub, "target_behavior:#{target_behavior.id}")

      Alethea.AI.PatternProposalChainMock
      |> expect(:run, fn %{sanitized_evidence: texts} ->
        assert Enum.any?(texts, &(&1 =~ "[REDACTED_EMAIL]"))
        refute Enum.any?(texts, &(&1 =~ "juan.perez@example.com"))

        {:ok, %{proposals: ["Podria existir un patron A", "Podria existir un patron B"]}}
      end)

      assert :ok =
               perform_job(AIProposalWorker, %{
                 "professional_id" => professional.id,
                 "patient_id" => patient.id,
                 "target_behavior_id" => target_behavior.id
               })

      assert_receive {:ai_proposals_ready, target_behavior_id}
      assert target_behavior_id == target_behavior.id

      proposals =
        AIProposal
        |> Alethea.Repo.all()
        |> Enum.filter(&(&1.target_behavior_id == target_behavior.id))

      assert length(proposals) == 2
      assert Enum.all?(proposals, &(&1.status == "pending"))
      assert Enum.all?(proposals, &(&1.professional_id == professional.id))
    end
  end

  describe "perform/1 — chain failure" do
    test "inserts no proposal rows and broadcasts failed", %{
      professional: professional,
      patient: patient,
      target_behavior: target_behavior
    } do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "target_behavior:#{target_behavior.id}")

      Alethea.AI.PatternProposalChainMock
      |> expect(:run, fn _params -> {:error, :timeout} end)

      assert {:error, :timeout} =
               perform_job(AIProposalWorker, %{
                 "professional_id" => professional.id,
                 "patient_id" => patient.id,
                 "target_behavior_id" => target_behavior.id
               })

      assert_receive {:ai_proposals_failed, :timeout}
      assert Alethea.Repo.aggregate(AIProposal, :count) == 0
    end
  end

  describe "perform/1 — unauthorized" do
    test "denies a professional not responsible for the patient: no chain call, no rows, broadcasts failed",
         %{patient: patient, target_behavior: target_behavior} do
      other_professional = create_professional!()

      Phoenix.PubSub.subscribe(Alethea.PubSub, "target_behavior:#{target_behavior.id}")

      # No `expect(:run, ...)` set on the mock — the chain must never be
      # called on the unauthorized branch (Mox would raise if it were).
      assert {:error, :unauthorized} =
               perform_job(AIProposalWorker, %{
                 "professional_id" => other_professional.id,
                 "patient_id" => patient.id,
                 "target_behavior_id" => target_behavior.id
               })

      assert_receive {:ai_proposals_failed, :unauthorized}
      assert Alethea.Repo.aggregate(AIProposal, :count) == 0
    end
  end

  describe "structural safety" do
    test "the worker module source never references a confirm/accept/note-write function" do
      source =
        Path.join([File.cwd!(), "lib", "alethea_jobs", "ai_proposal_worker.ex"])
        |> File.read!()

      refute source =~ "create_clinical_note"
      refute source =~ "accept_ai_proposal"
      refute source =~ "edit_ai_proposal"
      refute source =~ "discard_ai_proposal"
      refute source =~ "upsert_functional_analysis_draft"
    end

    test "the chain module source never references a confirm/accept/note-write function" do
      source =
        Path.join([File.cwd!(), "lib", "alethea", "ai", "chains", "pattern_proposal_chain.ex"])
        |> File.read!()

      refute source =~ "create_clinical_note"
      refute source =~ "accept_ai_proposal"
    end
  end

  defp insert_evidence!(professional, patient, target_behavior, source_kind, source_id, excerpt) do
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = Alethea.Encryption.PatientVault.encrypt(excerpt, dek)

    %ConsultationEvidence{}
    |> ConsultationEvidence.changeset(%{
      source_kind: source_kind,
      source_id: source_id,
      encrypted_excerpt: ciphertext,
      occurred_at: DateTime.utc_now(),
      patient_id: patient.id,
      professional_id: professional.id,
      target_behavior_id: target_behavior.id
    })
    |> Alethea.Repo.insert!()
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "ai-proposal-worker-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. AI Proposal Worker"
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
