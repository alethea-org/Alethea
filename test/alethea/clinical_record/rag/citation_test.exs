defmodule Alethea.ClinicalRecord.Rag.CitationTest do
  @moduledoc """
  ADR-010 §3 — "La evidencia y sus citas se derivan de la recuperación del
  paciente, no del contenido previo de la conversación."

  These specs pin the enforcement: a `Citation` is built only from a server
  retrieval result, and any `source_ref` not present in the original envelope
  is rejected at render time. The render itself is covered by
  `AletheaWeb.CoreComponents.CitationTest`.
  """

  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.Rag.Citation

  @valid_result %{
    chunk_id: "11111111-1111-1111-1111-111111111111",
    source_resource_type: "clinical_notes",
    source_resource_id: "22222222-2222-2222-2222-222222222222",
    source_occurred_at: ~U[2026-08-12 14:30:00Z],
    target_behavior_id: nil,
    chunk_index: 0,
    full_event: true,
    content: "El paciente reportó insomnio recurrente durante la última semana.",
    dense_distance: 0.12,
    lexical_score: 0.66,
    score: 0.83
  }

  describe "from_retrieval_result/1" do
    test "builds a citation from a server-side Retrieval.result map" do
      citation = Citation.from_retrieval_result(@valid_result)

      assert citation.excerpt == "El paciente reportó insomnio recurrente durante la última semana."
      assert citation.kind == "clinical_notes"
      assert citation.occurred_at == ~U[2026-08-12 14:30:00Z]
      assert citation.chunk_index == 0
      assert citation.score == 0.83
      assert is_binary(citation.source_ref)
      assert citation.source_ref != ""
    end

    test "preserves every server-derived field verbatim — no transformation" do
      citation = Citation.from_retrieval_result(@valid_result)

      assert citation.excerpt == @valid_result.content
      assert citation.kind == @valid_result.source_resource_type
      assert citation.occurred_at == @valid_result.source_occurred_at
      assert citation.chunk_index == @valid_result.chunk_index
    end

    test "rejects a non-map payload (free text cannot become a citation)" do
      assert_raise FunctionClauseError, fn ->
        Citation.from_retrieval_result("this is not a retrieval result")
      end
    end

    test "rejects a map without chunk_id — the server-derived anchor is missing" do
      stripped = Map.delete(@valid_result, :chunk_id)

      assert_raise ArgumentError, ~r/chunk_id/, fn ->
        Citation.from_retrieval_result(stripped)
      end
    end

    test "rejects a map without source_resource_id" do
      stripped = Map.delete(@valid_result, :source_resource_id)

      assert_raise ArgumentError, ~r/source_resource_id/, fn ->
        Citation.from_retrieval_result(stripped)
      end
    end

    test "rejects a map without source_resource_type (the kind)" do
      stripped = Map.delete(@valid_result, :source_resource_type)

      assert_raise ArgumentError, ~r/source_resource_type/, fn ->
        Citation.from_retrieval_result(stripped)
      end
    end

    test "rejects a map without the decrypted content (the excerpt)" do
      stripped = Map.delete(@valid_result, :content)

      assert_raise ArgumentError, ~r/content/, fn ->
        Citation.from_retrieval_result(stripped)
      end
    end

    test "rejects an empty excerpt — empty cite = decorative cite, not verifiable" do
      with_empty = Map.put(@valid_result, :content, "")

      assert_raise ArgumentError, ~r/excerpt/, fn ->
        Citation.from_retrieval_result(with_empty)
      end
    end

    test "accepts different source_resource_type values — any kind the indexer produces" do
      for kind <- ~w(clinical_notes session_transcripts journal_entries target_behaviors summaries) do
        result = Map.put(@valid_result, :source_resource_type, kind)
        citation = Citation.from_retrieval_result(result)
        assert citation.kind == kind
      end
    end
  end

  describe "ref/1" do
    test "is deterministic — same input → same ref" do
      a = Citation.ref(@valid_result)
      b = Citation.ref(@valid_result)
      assert a == b
    end

    test "differs across different source_resource_ids (collision-proof)" do
      b = Map.put(@valid_result, :source_resource_id, "33333333-3333-3333-3333-333333333333")

      assert Citation.ref(@valid_result) != Citation.ref(b)
    end

    test "differs across different chunk_index for the same source" do
      b = Map.put(@valid_result, :chunk_index, 1)

      assert Citation.ref(@valid_result) != Citation.ref(b)
    end

    test "encodes source_resource_type and chunk_index so the ref is human-readable" do
      ref = Citation.ref(@valid_result)
      assert ref =~ "clinical_notes"
      assert ref =~ "0"
    end
  end

  describe "reject_unknown_refs/2" do
    test "drops any cite whose ref is not in the server envelope" do
      c1 = Citation.from_retrieval_result(@valid_result)

      stolen =
        @valid_result
        |> Map.put(:content, "Texto inventado por el LLM")
        |> Map.put(:chunk_id, "deadbeef-0000-0000-0000-000000000000")

      c2 = Citation.from_retrieval_result(stolen)

      allowed = MapSet.new([Citation.ref(@valid_result)])
      assert Citation.reject_unknown_refs([c1, c2], allowed) == [c1]
    end

    test "keeps every cite when all refs are in the envelope" do
      c1 = Citation.from_retrieval_result(@valid_result)
      b = Map.put(@valid_result, :chunk_index, 1)
      c2 = Citation.from_retrieval_result(b)

      allowed = MapSet.new([Citation.ref(@valid_result), Citation.ref(b)])
      assert Citation.reject_unknown_refs([c1, c2], allowed) == [c1, c2]
    end

    test "returns an empty list when no ref matches (refuse to render invented cites)" do
      c1 = Citation.from_retrieval_result(@valid_result)
      assert Citation.reject_unknown_refs([c1], MapSet.new(["never-seen"])) == []
    end

    test "accepts a single MapSet argument for convenience at the call site" do
      c1 = Citation.from_retrieval_result(@valid_result)
      allowed = MapSet.new([Citation.ref(@valid_result)])
      assert Citation.reject_unknown_refs([c1], allowed) == [c1]
    end
  end
end
