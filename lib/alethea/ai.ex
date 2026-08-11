defmodule Alethea.AI do
  @moduledoc """
  Discovery surface for the AI integration slots of Alethea.

  ## What this module is

  The single entry point domain code uses to look up the configured
  adapter for each AI slot. The slots are:

  - `:ai_embeddings` — the embeddings adapter (RAG ingest).
  - `:ai_whisper`    — the Whisper transcription adapter (grabación → transcripción).

  Each slot is configured at boot via `config :alethea, :ai_*` and
  swapped per environment:

  - `:test` env  → the Fakes from `lib/alethea/ai/{embeddings,whisper}/fake.ex`.
  - `:dev` env   → also Fakes (safe; no network).
  - `:prod` env  → concrete adapters (HF Embeddings, Groq Whisper) —
                   not in this change; they land in
                   `ai-embeddings-hf-foundation` and `ai-whisper-groq-foundation`.

  ## Why a separate module

  ADR-002/003 promise "swap the provider, not the domain code".
  The behaviours `Alethea.AI.Embeddings` and `Alethea.AI.Whisper`
  are the **contract**. The adapters are the **concrete**. This
  module is the **discovery** — the place domain code goes to ask
  "which adapter is wired right now?".

  ## Boundary with the legacy `Alethea.AI.*` namespace

  The legacy `Alethea.AI.LLMConfig`, `Alethea.AI.PhiWorker`, etc.
  remain the v1 LangChain / local model surface. The v2 swap point
  here is parallel: the future
  AI feature changes (RAG ingest, psicometría batch, etc.) will
  call `Alethea.AI.embeddings/0` / `Alethea.AI.whisper/0` and
  dispatch into the configured adapter. The legacy code is
  untouched by this change.
  """

  @doc """
  Returns the module configured at `:ai_embeddings`.
  Raises `RuntimeError` with a clear message if not configured.
  """
  @spec embeddings() :: module()
  def embeddings, do: configured!(:ai_embeddings)

  @doc """
  Returns the module configured at `:ai_whisper`.
  Raises `RuntimeError` with a clear message if not configured.
  """
  @spec whisper() :: module()
  def whisper, do: configured!(:ai_whisper)

  # Single-sourced helper so the error format and the call to
  # Application.fetch_env! are consistent across both slots.
  defp configured!(key) do
    Application.fetch_env!(:alethea, key)
  rescue
    ArgumentError ->
      raise "AI adapter for #{inspect(key)} is not configured. " <>
              "Set config :alethea, #{inspect(key)}, YourAdapterModule in your environment config."
  end
end
