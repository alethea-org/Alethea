defmodule Alethea.AI.Whisper do
  @moduledoc """
  Behaviour contract for audio transcription.

  ## Purpose

  Whisper turns the audio of a `Grabación` (per
  `openspec/UBIQUITOUS_LANGUAGE.md`) into a `Transcripción` that
  enters the RAG (the patient's historia clínica navegable,
  per ADR-003). Per `openspec/adr/001-llm-en-groq.md`, the production
  Whisper adapter runs on Groq.

  ## Input shape

  The first argument to `transcribe/2` is intentionally a union
  (`binary() | String.t()`): adapters may receive either a raw audio
  binary (from a direct upload) or a string file path (from a storage
  layer that pre-stages the file). The behaviour does not constrain
  the choice — the adapter decides.

  ## Output shape

  `transcription()` is a map with `text` (the full transcript),
  `segments` (a list of `%{start, end, text}` for time-anchored
  citations in the RAG), and `language` (detected or hinted).
  `language` may be `nil` if the adapter did not detect it.

  ## Boundary with the legacy `Alethea.AI.*` namespace

  The legacy `Alethea.AI.Sanitizer` is the v1 input normalizer for
  text-based AI inputs. It is unrelated to audio. The v2 behaviour
  here is parallel: the future `grabacion-transcripcion-foundation`
  change wires the Whisper adapter to the storage layer.

  ## Adapter discovery

  Domain code dispatches through `Alethea.AI.whisper/0` (see
  `lib/alethea/ai.ex`), which reads `config :alethea, :ai_whisper`.
  The default in `:test` env is `Alethea.AI.Whisper.Fake`.

  ## What concrete implementations are out of scope here

  - `Alethea.AI.Whisper.Groq` → `ai-whisper-groq-foundation`
  """

  @typedoc "A timestamped segment of a transcription, suitable for time-anchored citations in the RAG."
  @type segment :: %{start: number(), end: number(), text: String.t()}

  @typedoc "The full transcription of a grabación."
  @type transcription :: %{
          text: String.t(),
          segments: [segment()],
          language: String.t() | nil
        }

  @typedoc "An audio input — a raw binary (e.g., from a multipart upload) or a string file path (e.g., from a storage layer)."
  @type audio :: binary() | String.t()

  @doc """
  Transcribes an audio input into a `transcription/0` map.
  """
  @callback transcribe(audio :: audio(), opts :: keyword()) ::
              {:ok, transcription()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Alethea.AI.Whisper
    end
  end
end
