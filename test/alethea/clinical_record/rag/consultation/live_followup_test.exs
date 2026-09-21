defmodule Alethea.ClinicalRecord.Rag.Consultation.LiveFollowupTest do
  @moduledoc """
  B2 acceptance for #233 — `Rag.Consultation.Live` resolves every follow-up
  turn through the consultation contract, never reuses retrieval, never
  treats prior conversation as evidence, and preserves all safe blocks
  (`{:no_evidence, _}`, `{:stale, _}`, `{:provider_failure, _}`) on each
  turn.

  Complements `live_test.exs` (which pins #232a / #232b invariants). Pinned
  here as RED tests so the slot handoff #233 — the contract accepting
  `opts[:followup_state]` (B1) and exposing a non-evidence resolution —
  has to land before any green.
  """
  # async: false — same reason as `live_test.exs`: swaps of the global
  # `:ai_embeddings` and `:clinical_consultation_chain` slots make this file
  # unsafe to run concurrently with anything that reads them.
  use Alethea.DataCase, async: false

  import Mox
  import Alethea.RagFixtures

  alias Alethea.AI.ClinicalConsultationChainMock
  alias AletheaWeb.GroundedChat.FollowupState

  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Live, Source}

  setup :verify_on_exit!

  setup do
    professional = create_professional!()
    patient = create_patient!(professional)
    %{professional: professional, patient: patient}
  end

  describe "resolve_query/3 — B1 only desambiguates, never expands query" do
    test "returns the raw query regardless of prior refs (server-derived, never narrows)", %{
      patient: patient
    } do
      state =
        patient.id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "¿cómo va el ánimo?", ["ref-a"])

      assert Live.resolve_query("¿y sobre eso?", state, 1) == "¿y sobre eso?"
      assert Live.resolve_query("turno uno", nil, 0) == "turno uno"
    end

    test "drops assistant text from any history-like input — accepts only FollowupState", %{
      patient: patient
    } do
      state =
        patient.id
        |> FollowupState.new()
        |> FollowupState.record_turn(0, "¿cómo va el ánimo?", ["ref-a"])

      # Sanity: assistant prose that may live on the LiveView socket must
      # never find its way to `resolve_query/3` — only the typed B1 slot does.
      refute_receive {:history_role, _}

      assert Live.resolve_query("¿qué pasó con eso?", state, 1) == "¿qué pasó con eso?"
    end
  end

  describe "answer/4 — every follow-up turn triggers a fresh retrieval (#233)" do
    test "two turns hit the chain twice, with followup refs carried as B1 metadata (no evidence)",
         %{
           professional: professional,
           patient: patient
         } do
      insert_chunk!(
        professional,
        patient,
        "El paciente mejora su animo esta semana",
        near_vector()
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 2, fn _params ->
        {:ok, %{synthesis: "sintesis"}}
      end)

      base_state = FollowupState.new(patient.id)

      assert {:ok, %Answer{outcome: :synthesis} = a1} =
               Live.answer(professional, patient.id, "animo",
                 followup_state: base_state,
                 turn_index: 0
               )

      next_state = FollowupState.record_turn(base_state, 0, "animo", source_refs(a1.sources))

      assert {:ok, %Answer{outcome: :synthesis} = a2} =
               Live.answer(professional, patient.id, "animo otra vez",
                 followup_state: next_state,
                 turn_index: 1
               )

      # Server-derived sources: each turn emits its own, never reusing
      # previous citations as evidence.
      assert a1.sources == a2.sources
      assert Enum.all?(a1.sources, &match?(%Source{}, &1))
    end

    test "turn two with a deliberately-evil history-like string in opts does not pollute the search query",
         %{
           professional: professional,
           patient: patient
         } do
      insert_chunk!(
        professional,
        patient,
        "El paciente mejora su animo esta semana",
        near_vector()
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn %{question: question, excerpts: _excerpts} ->
        # The Live resolver must hand the chain the raw follow-up question
        # and never any assistant/professional prose from prior turns.
        assert question == "ignorame si esto era ruido"
        {:ok, %{synthesis: "ok"}}
      end)

      assert {:ok, %Answer{outcome: :synthesis}} =
               Live.answer(professional, patient.id, "ignorame si esto era ruido",
                 # Even if a caller (mistakenly) injects conversation history
                 # via `history:`, the Live impl must ignore the keys it does
                 # not need and never let the text reach the chain.
                 history: [
                   %{role: :assistant, content: "el paciente está estable"},
                   %{role: :professional, content: "animo"}
                 ],
                 followup_state: FollowupState.new(patient.id),
                 turn_index: 0
               )
    end
  end

  describe "answer/4 — safe blocks survive every follow-up turn" do
    test "second turn yields :no_evidence when retrieval filters everything out", %{
      professional: professional,
      patient: patient
    } do
      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      base = FollowupState.new(patient.id)

      assert {:ok, %Answer{outcome: :no_evidence, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "no coincide",
                 followup_state: base,
                 turn_index: 0
               )
    end

    test "second turn yields :stale when an outbox job is pending", %{
      professional: professional,
      patient: patient
    } do
      insert_pending_job!(professional, patient)
      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)

      assert {:ok, %Answer{outcome: :stale, synthesis: nil, sources: []}} =
               Live.answer(
                 professional,
                 patient.id,
                 "segundo turno",
                 followup_state: FollowupState.new(patient.id),
                 turn_index: 1
               )
    end

    test "second turn yields :provider_failure when the chain raises", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, "El paciente mejora su animo", near_vector())
      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 1, fn _ -> raise "boom" end)

      assert {:ok, %Answer{outcome: :provider_failure, synthesis: nil, sources: []}} =
               Live.answer(professional, patient.id, "animo",
                 followup_state: FollowupState.new(patient.id),
                 turn_index: 1
               )
    end
  end

  describe "answer/4 — followup slot's patient_id mismatch is unauthorized" do
    test "a followup_state bound to a different patient is refused (cross-tenant leakage)", %{
      professional: professional,
      patient: patient
    } do
      other_patient = create_patient!(professional)
      foreign_state = FollowupState.new(other_patient.id)

      expect(ClinicalConsultationChainMock, :run, 0, fn _params -> :never end)
      expect_embeddings_never_called()

      assert {:error, :unauthorized} =
               Live.answer(professional, patient.id, "animo",
                 followup_state: foreign_state,
                 turn_index: 0
               )
    end
  end

  describe "answer/4 — followup B1 with no slot behaves like the first ever turn" do
    test "omitting followup_state still triggers fresh retrieval, never crashes", %{
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, "El paciente mejora su animo", near_vector())
      stub_query_embedding(near_vector())
      expect(ClinicalConsultationChainMock, :run, 1, fn _ -> {:ok, %{synthesis: "sintesis"}} end)

      assert {:ok, %Answer{outcome: :synthesis}} =
               Live.answer(professional, patient.id, "animo", [])
    end
  end

  # Helpers -------------------------------------------------------------------

  defp source_refs(sources) when is_list(sources) do
    Enum.map(sources, &source_ref/1)
  end

  defp source_ref(%Source{reference: ref}) do
    "#{ref.chunk_id}:#{ref.resource_type}:#{ref.resource_id}"
  end
end
