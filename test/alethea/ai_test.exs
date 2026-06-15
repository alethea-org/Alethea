defmodule Alethea.AITest do
  @moduledoc """
  Adapter-discovery tests for the top-level `Alethea.AI` module.

  Per `openspec/sdd/bootstrap-alethea-v2/03-tasks.md` (Phase 7):

  - `Alethea.AI.llm/0` returns the module configured at `:ai_llm`.
  - `Alethea.AI.embeddings/0` returns the module at `:ai_embeddings`.
  - `Alethea.AI.whisper/0` returns the module at `:ai_whisper`.
  - The discovery functions raise a clear error if the config key
    is missing (future-proofs against misconfiguration in `:dev` env
    that does not have the Fakes wired).
  """

  use ExUnit.Case, async: false

  alias Alethea.AI

  describe "adapter discovery (happy path)" do
    test "llm/0 returns the module configured at :ai_llm" do
      assert AI.llm() == Alethea.AI.LLM.Fake
    end

    test "embeddings/0 returns the module configured at :ai_embeddings" do
      assert AI.embeddings() == Alethea.AI.Embeddings.Fake
    end

    test "whisper/0 returns the module configured at :ai_whisper" do
      assert AI.whisper() == Alethea.AI.Whisper.Fake
    end
  end

  describe "adapter discovery (missing config raises clearly)" do
    test "llm/0 raises with a clear error when :ai_llm is not configured" do
      original = Application.get_env(:alethea, :ai_llm)
      Application.delete_env(:alethea, :ai_llm)

      try do
        assert_raise RuntimeError, ~r/:ai_llm/, fn -> AI.llm() end
      after
        # Restore the original config so other tests are not affected.
        if original do
          Application.put_env(:alethea, :ai_llm, original, persistent: true)
        end
      end
    end

    test "embeddings/0 raises with a clear error when :ai_embeddings is not configured" do
      original = Application.get_env(:alethea, :ai_embeddings)
      Application.delete_env(:alethea, :ai_embeddings)

      try do
        assert_raise RuntimeError, ~r/:ai_embeddings/, fn -> AI.embeddings() end
      after
        if original do
          Application.put_env(:alethea, :ai_embeddings, original, persistent: true)
        end
      end
    end

    test "whisper/0 raises with a clear error when :ai_whisper is not configured" do
      original = Application.get_env(:alethea, :ai_whisper)
      Application.delete_env(:alethea, :ai_whisper)

      try do
        assert_raise RuntimeError, ~r/:ai_whisper/, fn -> AI.whisper() end
      after
        if original do
          Application.put_env(:alethea, :ai_whisper, original, persistent: true)
        end
      end
    end
  end
end
