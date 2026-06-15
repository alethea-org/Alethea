defmodule Alethea.AI.AdapterDiscoveryTest do
  @moduledoc """
  Config-discovery tests for the AI adapter slots.

  Per `openspec/sdd/bootstrap-alethea-v2/specs/ai/spec.md` (the
  "Adapter Discovery Through Application Config" requirement):

  - `:test` env has Fake adapters configured for `:ai_llm`,
    `:ai_embeddings`, `:ai_whisper`.

  The fact that the configured module implements the corresponding
  behaviour is covered by the per-behaviour test files
  (`test/alethea/ai/llm_test.exs`, etc.); this file's job is just
  the swap-point: confirming the config keys exist and point at a
  loaded module that can be dispatched to.
  """

  use ExUnit.Case, async: false

  describe "test env adapter configuration" do
    test ":ai_llm is configured to the LLM Fake" do
      mod = Application.fetch_env!(:alethea, :ai_llm)
      assert mod == Alethea.AI.LLM.Fake
      assert Code.ensure_loaded?(mod)
    end

    test ":ai_embeddings is configured to the Embeddings Fake" do
      mod = Application.fetch_env!(:alethea, :ai_embeddings)
      assert mod == Alethea.AI.Embeddings.Fake
      assert Code.ensure_loaded?(mod)
    end

    test ":ai_whisper is configured to the Whisper Fake" do
      mod = Application.fetch_env!(:alethea, :ai_whisper)
      assert mod == Alethea.AI.Whisper.Fake
      assert Code.ensure_loaded?(mod)
    end
  end
end
