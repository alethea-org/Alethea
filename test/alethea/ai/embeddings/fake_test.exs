defmodule Alethea.AI.Embeddings.FakeTest do
  @moduledoc """
  Contract tests for `Alethea.AI.Embeddings.Fake` under the revised
  ADR-002 shape (`sdd/clinical-rag-projection`, GitHub #196, WU1/design
  point 4). The prior Fake returned `[0.0]` (1-dim, all-zero), which is
  unusable for `vector(1024)` and produces NaN under pgvector cosine
  `<=>`. This module asserts the Fake now emits deterministic,
  input-derived, non-zero 1024-dim vectors — matching BGE-M3's output
  shape (ADR-002) without any network call.
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.Embeddings.Fake

  describe "dimensions/0" do
    test "returns 1024, matching BGE-M3's output shape (ADR-002)" do
      assert Fake.dimensions() == 1024
    end
  end

  describe "embed/2 with a single string" do
    test "returns a 1024-element vector" do
      assert {:ok, vector} = Fake.embed("hola clínica", [])
      assert length(vector) == 1024
    end

    test "returns a non-zero vector (not all zeroes)" do
      assert {:ok, vector} = Fake.embed("hola clínica", [])
      refute Enum.all?(vector, &(&1 == 0.0))
    end

    test "every element is a float" do
      assert {:ok, vector} = Fake.embed("hola clínica", [])
      assert Enum.all?(vector, &is_float/1)
    end

    test "is deterministic across repeated calls for the same input" do
      assert {:ok, vector_a} = Fake.embed("paciente refiere ansiedad", [])
      assert {:ok, vector_b} = Fake.embed("paciente refiere ansiedad", [])
      assert vector_a == vector_b
    end

    test "is input-derived: different text yields a different vector (triangulation)" do
      assert {:ok, vector_a} = Fake.embed("texto uno", [])
      assert {:ok, vector_b} = Fake.embed("texto dos", [])
      refute vector_a == vector_b
    end
  end

  describe "embed/2 with a list of strings" do
    test "returns one 1024-element vector per input, in order" do
      assert {:ok, [vector_one, vector_two]} = Fake.embed(["uno", "dos"], [])
      assert length(vector_one) == 1024
      assert length(vector_two) == 1024
      refute vector_one == vector_two
    end

    test "batch vectors match the single-embed vector for the same text (consistency)" do
      assert {:ok, single_vector} = Fake.embed("mismo texto", [])
      assert {:ok, [batch_vector]} = Fake.embed(["mismo texto"], [])
      assert single_vector == batch_vector
    end
  end
end
