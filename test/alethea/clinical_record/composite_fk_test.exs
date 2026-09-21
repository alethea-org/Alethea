defmodule Alethea.ClinicalRecord.CompositeFkTest do
  @moduledoc """
  Database-level `(target_behavior_id, patient_id)` consistency (GitHub #289).

  Every child table of `target_behaviors` carries both `patient_id` and
  `target_behavior_id` as independent single-column FKs, so Postgres alone
  accepted a row pairing patient A with patient B's target behavior. The
  composite FK `<table>_target_behavior_patient_fkey` makes that pair
  impossible for any writer, not just `Alethea.ClinicalRecord`.

  Rows are inserted straight through their changesets (bypassing the
  context's `with_target_behavior/4` seam) so these tests exercise the
  constraint itself.

  `clinical_record_tombstones` is intentionally absent: it carries no FK by
  design, because the target behavior can be legally deleted while its
  tombstone survives.
  """
  use Alethea.DataCase, async: false

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicianObservation,
    ConsultationEvidence,
    FunctionalAnalysisDraft
  }

  alias Alethea.ClinicalRecord.Rag.Chunk

  @password "supersecret12"

  @tables ~w(
    consultation_evidences
    clinician_observations
    ai_proposals
    functional_analysis_drafts
    clinical_record_rag_chunks
  )

  # Tables whose rows are removed together with their target behavior
  # (`ON DELETE CASCADE`), as opposed to `clinical_record_rag_chunks`, which
  # keeps the chunk and only loses the facet (`ON DELETE SET NULL`).
  @cascading_tables @tables -- ["clinical_record_rag_chunks"]

  setup do
    professional = create_professional!()
    patient_a = create_patient!(professional)
    patient_b = create_patient!(professional)

    {:ok, target_b} = ClinicalRecord.create_target_behavior(professional, patient_b.id, "B")

    %{professional: professional, patient_a: patient_a, patient_b: patient_b, target_b: target_b}
  end

  describe "a mismatched (patient_id, target_behavior_id) pair is rejected by the database" do
    for table <- @tables do
      test "#{table}", %{professional: professional, patient_a: patient_a, target_b: target_b} do
        error =
          assert_raise Ecto.ConstraintError, fn ->
            insert_row!(unquote(table), professional, patient_a.id, target_b.id)
          end

        assert error.constraint == "#{unquote(table)}_target_behavior_patient_fkey"
      end
    end
  end

  describe "a consistent pair is accepted" do
    for table <- @tables do
      test "#{table}", %{professional: professional, patient_b: patient_b, target_b: target_b} do
        assert insert_row!(unquote(table), professional, patient_b.id, target_b.id)
      end
    end
  end

  describe "deleting a target behavior" do
    test "still cascades to the child tables that cascade today", %{
      professional: professional,
      patient_b: patient_b,
      target_b: target_b
    } do
      for table <- @cascading_tables,
          do: insert_row!(table, professional, patient_b.id, target_b.id)

      Repo.delete!(target_b)

      for table <- @cascading_tables do
        assert count(table) == 0, "expected #{table} to cascade-delete with its target behavior"
      end
    end

    test "nilifies only rag_chunks.target_behavior_id and keeps its patient_id", %{
      professional: professional,
      patient_b: patient_b,
      target_b: target_b
    } do
      chunk = insert_row!("clinical_record_rag_chunks", professional, patient_b.id, target_b.id)

      Repo.delete!(target_b)

      reloaded = Repo.get!(Chunk, chunk.id)
      assert reloaded.target_behavior_id == nil
      assert reloaded.patient_id == patient_b.id
    end
  end

  defp count(table), do: Repo.aggregate(table, :count)

  defp insert_row!("consultation_evidences", professional, patient_id, target_behavior_id) do
    %ConsultationEvidence{}
    |> ConsultationEvidence.changeset(%{
      source_kind: "clinical_note",
      source_id: Ecto.UUID.generate(),
      encrypted_excerpt: <<1, 2, 3>>,
      occurred_at: DateTime.utc_now(),
      patient_id: patient_id,
      professional_id: professional.id,
      target_behavior_id: target_behavior_id
    })
    |> Repo.insert!()
  end

  defp insert_row!("clinician_observations", professional, patient_id, target_behavior_id) do
    %ClinicianObservation{}
    |> ClinicianObservation.changeset(%{
      encrypted_body: <<1, 2, 3>>,
      occurred_at: DateTime.utc_now(),
      patient_id: patient_id,
      professional_id: professional.id,
      target_behavior_id: target_behavior_id
    })
    |> Repo.insert!()
  end

  defp insert_row!("ai_proposals", professional, patient_id, target_behavior_id) do
    %AIProposal{}
    |> AIProposal.changeset(%{
      encrypted_original_text: <<1, 2, 3>>,
      encrypted_text: <<1, 2, 3>>,
      model_version: "test-model",
      occurred_at: DateTime.utc_now(),
      patient_id: patient_id,
      professional_id: professional.id,
      target_behavior_id: target_behavior_id
    })
    |> Repo.insert!()
  end

  defp insert_row!("functional_analysis_drafts", professional, patient_id, target_behavior_id) do
    %FunctionalAnalysisDraft{}
    |> FunctionalAnalysisDraft.changeset(%{
      encrypted_body: <<1, 2, 3>>,
      patient_id: patient_id,
      professional_id: professional.id,
      target_behavior_id: target_behavior_id
    })
    |> Repo.insert!()
  end

  defp insert_row!("clinical_record_rag_chunks", professional, patient_id, target_behavior_id) do
    %Chunk{}
    |> Chunk.changeset(%{
      source_resource_type: "clinical_note",
      source_resource_id: Ecto.UUID.generate(),
      chunk_index: 0,
      encrypted_content: <<1, 2, 3>>,
      embedding: List.duplicate(0.1, 1024),
      embedding_model: "test-embedding",
      token_count: 1,
      source_occurred_at: DateTime.utc_now(),
      patient_id: patient_id,
      professional_id: professional.id,
      target_behavior_id: target_behavior_id
    })
    |> Repo.insert!()
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "composite-fk-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Composite FK"
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
