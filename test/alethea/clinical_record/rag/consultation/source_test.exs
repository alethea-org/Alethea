defmodule Alethea.ClinicalRecord.Rag.Consultation.SourceTest do
  @moduledoc """
  `Source.from_results/1` is the server-side half of source provenance
  (#226a): it maps a `Rag.Retrieval.search/4` envelope result list 1:1
  into `%Source{}` structs with verbatim excerpts and a stable reference,
  adding nothing the retrieval layer did not already produce.
  """
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.Rag.Consultation.Source

  defp result(overrides) do
    Map.merge(
      %{
        chunk_id: Ecto.UUID.generate(),
        source_resource_type: "clinical_note",
        source_resource_id: Ecto.UUID.generate(),
        source_occurred_at: ~U[2026-01-01 00:00:00Z],
        target_behavior_id: nil,
        content: "contenido"
      },
      Map.new(overrides)
    )
  end

  describe "from_results/1" do
    test "maps every envelope result 1:1 with a verbatim excerpt and a stable reference" do
      r1 =
        result(
          source_resource_type: "clinical_note",
          source_occurred_at: ~U[2026-01-15 10:00:00Z],
          content: "El paciente reporta evitación de reuniones sociales"
        )

      r2 =
        result(
          source_resource_type: "session_summary",
          target_behavior_id: Ecto.UUID.generate(),
          source_occurred_at: ~U[2026-02-20 09:30:00Z],
          content: "Se observa mejoría del ánimo tras la exposición gradual"
        )

      assert [s1, s2] = Source.from_results([r1, r2])

      assert s1.excerpt == r1.content
      assert s1.kind == "clinical_note"
      assert s1.occurred_at == ~U[2026-01-15 10:00:00Z]

      assert s1.reference == %{
               chunk_id: r1.chunk_id,
               resource_type: "clinical_note",
               resource_id: r1.source_resource_id,
               target_behavior_id: nil
             }

      assert s2.excerpt == r2.content
      assert s2.kind == "session_summary"
      assert s2.reference.target_behavior_id == r2.target_behavior_id
      assert s2.reference.resource_id == r2.source_resource_id
    end

    test "returns exactly one source per input result and fabricates none (triangulation)" do
      results = for _ <- 1..3, do: result([])

      sources = Source.from_results(results)

      assert length(sources) == 3
      assert Enum.map(sources, & &1.excerpt) == Enum.map(results, & &1.content)
      assert Enum.map(sources, & &1.reference.chunk_id) == Enum.map(results, & &1.chunk_id)
    end

    test "an empty envelope yields no sources" do
      assert Source.from_results([]) == []
    end
  end
end
