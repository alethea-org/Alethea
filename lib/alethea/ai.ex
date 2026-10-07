defmodule Alethea.AI do
  @moduledoc """
  Discovery surface for the AI integration slots of Alethea.

  ## What this module is

  The single entry point domain code uses to look up the configured
  adapter for each AI slot. The slots are:

  - `:ai_embeddings` — the embeddings adapter (RAG ingest).
  - `:ai_whisper`    — the Whisper transcription adapter (grabación → transcripción).
  - `:emotion_analyzer` — the development-only emotion analyzer adapter.

  Each slot is configured at boot via `config :alethea, :ai_*` (and
  `:emotion_analyzer`) and swapped per environment:

  - `:test` env  → the Fakes from `lib/alethea/ai/{embeddings,whisper,emotion_analyzer}/fake.ex`.
  - `:dev` env   → also Fakes (safe; no network).
  - `:prod` env  → every slot is wired explicitly by `config/runtime.exs`
                   (issue #402): either the concrete adapter, enabled
                   through its environment switch together with its
                   endpoint, or the slot's `Disabled` adapter. No Fake
                   is reachable there. The emotion analyzer stays a
                   development-only capability (issue #198); whether a
                   deployment enables it is a product decision.

  ## Disabled capabilities

  "Disabled" is a configured state, not a missing key. `enabled?/1`
  answers whether a slot can do work, so a caller can skip an optional
  step instead of treating a switched-off capability as a failure. A
  caller that does not ask still gets a tagged error from the `Disabled`
  adapter, never fabricated data.

  ## Why a separate module

  ADR-002/003 promise "swap the provider, not the domain code".
  The behaviours `Alethea.AI.Embeddings`, `Alethea.AI.Whisper`, and
  `Alethea.AI.EmotionAnalyzerBehaviour` are the **contract**. The
  adapters are the **concrete**. This module is the **discovery** —
  the place domain code goes to ask "which adapter is wired right
  now?".

  ## Boundary with the legacy `Alethea.AI.*` namespace

  The legacy `Alethea.AI.LLMConfig`, `Alethea.AI.PhiWorker`, etc.
  remain the v1 LangChain / local model surface. The v2 swap point
  here is parallel: the future
  AI feature changes (RAG ingest, psicometría batch, etc.) will
  call `Alethea.AI.embeddings/0` / `Alethea.AI.whisper/0` and
  dispatch into the configured adapter. The legacy code is
  untouched by this change.
  """

  @typedoc "A discovery slot of this module."
  @type slot :: :ai_embeddings | :ai_whisper | :emotion_analyzer

  @disabled_adapters %{
    ai_embeddings: Alethea.AI.Embeddings.Disabled,
    ai_whisper: Alethea.AI.Whisper.Disabled,
    emotion_analyzer: Alethea.AI.EmotionAnalyzer.Disabled
  }

  @doc """
  Whether the capability behind `slot` is wired to a working adapter.

  Returns `false` when the slot holds its `Disabled` adapter and also
  when it is not configured at all, so asking never raises.
  """
  @spec enabled?(slot()) :: boolean()
  def enabled?(slot) when is_map_key(@disabled_adapters, slot) do
    case Application.fetch_env(:alethea, slot) do
      {:ok, adapter} -> adapter != disabled_adapter(slot)
      :error -> false
    end
  end

  @doc """
  Returns the adapter that represents the disabled state of `slot`.
  """
  @spec disabled_adapter(slot()) :: module()
  def disabled_adapter(slot) when is_map_key(@disabled_adapters, slot),
    do: Map.fetch!(@disabled_adapters, slot)

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

  @doc """
  Returns the module configured at `:emotion_analyzer`.

  The emotion-analyzer slot is the development-only capability scoped
  by issue #198 — it is wired to a deterministic Fake in `:test` and
  `:dev`, and remains explicitly development-only (no clinical
  validity, benchmarking, commercial licensing, or training-data
  provenance claims).

  Raises `RuntimeError` with a clear message if not configured.
  """
  @spec emotion_analyzer() :: module()
  def emotion_analyzer, do: configured!(:emotion_analyzer)

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
