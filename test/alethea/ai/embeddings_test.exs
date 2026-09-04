defmodule Alethea.AI.EmbeddingsTest do
  @moduledoc """
  Behaviour contract tests for `Alethea.AI.Embeddings` and its Fake adapter.

  Per `openspec/sdd/bootstrap-alethea-v2/specs/ai/spec.md`:

  - The behaviour declares `embed/2`, `model/0`, `dimensions/0`.
  - `behaviour_info(:callbacks)` includes all three.
  - A module that `use Alethea.AI.Embeddings` without `embed/2` (or
    without the metadata callbacks) gets a compiler warning.
  - The Fake adapter returns deterministic, contract-compliant tuples
    for both the single-text and batch shapes.
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.Embeddings

  describe "behaviour contract" do
    test "behaviour_info/1 lists embed/2, model/0, and dimensions/0" do
      callbacks = Embeddings.behaviour_info(:callbacks)
      assert {:embed, 2} in callbacks
      assert {:model, 0} in callbacks
      assert {:dimensions, 0} in callbacks
    end

    test "use Alethea.AI.Embeddings without embed/2 emits a compiler warning" do
      code = """
      defmodule Alethea.AI.EmbeddingsTest.WarningProbe do
        use Alethea.AI.Embeddings
        # NOTE: embed/2 is intentionally missing
        def model, do: "fake-model"
        def dimensions, do: 1
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)
      |> tap(&send(self(), {:stderr, &1}))
      |> then(fn _ -> :ok end)

      assert_received {:stderr, stderr}
      assert stderr =~ "embed"
    end
  end

  describe "Alethea.AI.Embeddings.Fake adapter" do
    alias Alethea.AI.Embeddings.Fake

    # Fake-specific vector-shape/determinism assertions moved to the
    # dedicated `test/alethea/ai/embeddings/fake_test.exs`
    # (sdd/clinical-rag-projection, WU1) since the Fake's contract
    # changed from a 1-dim all-zero stub to a 1024-dim non-zero,
    # input-derived vector (ADR-002 revision, design point 4). This
    # describe block keeps only the metadata-shape assertions that are
    # independent of the vector's dimensionality/content.

    test "embed/2 with a single string returns a single vector (shape only)" do
      assert {:ok, [_ | _] = vector} = Fake.embed("hola", [])
      assert Enum.all?(vector, &is_float/1)
    end

    test "embed/2 with a list of strings returns a list of vectors in order" do
      assert {:ok, vectors} = Fake.embed(["uno", "dos"], [])
      assert is_list(vectors)
      assert length(vectors) == 2
      # Each element is itself a list of floats (one vector per input).
      assert Enum.all?(vectors, fn v -> is_list(v) and Enum.all?(v, &is_float/1) end)
    end

    test "model/0 returns a string identifying the fake model" do
      assert model = Fake.model()
      assert is_binary(model)
      assert model != ""
    end

    test "dimensions/0 returns a positive integer" do
      dims = Fake.dimensions()
      assert is_integer(dims)
      assert dims > 0
    end

    test "model/0 and dimensions/0 are stable across calls" do
      # Triangulation: metadata is consistent — domain code can pin
      # both for pgvector column sizing.
      assert Fake.model() == Fake.model()
      assert Fake.dimensions() == Fake.dimensions()
    end
  end
end
