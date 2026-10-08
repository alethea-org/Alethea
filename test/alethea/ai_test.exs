defmodule Alethea.AITest do
  @moduledoc """
  Adapter-discovery tests for the top-level `Alethea.AI` module.

  Per `openspec/sdd/bootstrap-alethea-v2/03-tasks.md` (Phase 7):

  - `Alethea.AI.embeddings/0` returns the module at `:ai_embeddings`.
  - `Alethea.AI.whisper/0` returns the module at `:ai_whisper`.
  - The discovery functions raise a clear error if the config key
    is missing (future-proofs against misconfiguration in `:dev` env
    that does not have the Fakes wired).
  """

  use ExUnit.Case, async: false

  alias Alethea.AI

  describe "adapter discovery (happy path)" do
    test "embeddings/0 returns the module configured at :ai_embeddings" do
      assert AI.embeddings() == Alethea.AI.Embeddings.Fake
    end

    test "whisper/0 returns the module configured at :ai_whisper" do
      assert AI.whisper() == Alethea.AI.Whisper.Fake
    end
  end

  describe "enabled?/1" do
    test "is true for a slot wired to a working adapter" do
      assert AI.enabled?(:ai_embeddings)
      assert AI.enabled?(:ai_whisper)
      assert AI.enabled?(:emotion_analyzer)
    end

    test "is false for a slot wired to its Disabled adapter" do
      for {slot, disabled} <- [
            ai_embeddings: Alethea.AI.Embeddings.Disabled,
            ai_whisper: Alethea.AI.Whisper.Disabled,
            emotion_analyzer: Alethea.AI.EmotionAnalyzer.Disabled
          ] do
        with_slot(slot, disabled, fn ->
          refute AI.enabled?(slot)
          # Discovery still returns a module that honours the behaviour.
          assert AI.disabled_adapter(slot) == disabled
        end)
      end
    end

    test "is false, without raising, for a slot that is not configured" do
      with_slot(:emotion_analyzer, nil, fn -> refute AI.enabled?(:emotion_analyzer) end)
    end
  end

  describe "Disabled adapters" do
    test "embeddings report the disabled state and never produce vectors" do
      with_slot(:ai_embeddings, Alethea.AI.Embeddings.Disabled, fn ->
        assert AI.embeddings().embed("synthetic text", []) == {:error, :disabled}
        assert AI.embeddings().embed(["synthetic text"], []) == {:error, :disabled}
        assert AI.embeddings().model() == "disabled"
      end)
    end

    test "transcription reports the disabled state and never fabricates a transcript" do
      with_slot(:ai_whisper, Alethea.AI.Whisper.Disabled, fn ->
        assert AI.whisper().transcribe("synthetic-audio", []) == {:error, :disabled}
      end)
    end

    test "emotion analysis fails closed and never fabricates scores" do
      with_slot(:emotion_analyzer, Alethea.AI.EmotionAnalyzer.Disabled, fn ->
        assert AI.emotion_analyzer().analyze_batch(["synthetic text"]) == {:error, :unavailable}
      end)
    end
  end

  describe "adapter discovery (missing config raises clearly)" do
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

  defp with_slot(slot, adapter, fun) do
    original = Application.fetch_env(:alethea, slot)

    if adapter,
      do: Application.put_env(:alethea, slot, adapter),
      else: Application.delete_env(:alethea, slot)

    try do
      fun.()
    after
      case original do
        {:ok, value} -> Application.put_env(:alethea, slot, value)
        :error -> Application.delete_env(:alethea, slot)
      end
    end
  end
end
