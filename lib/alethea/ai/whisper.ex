defmodule Alethea.AI.Whisper do
  @moduledoc """
  Behaviour contract for audio transcription.

  ## Purpose

  Whisper turns the audio of a `Grabación` (per
  `openspec/UBIQUITOUS_LANGUAGE.md`) into a `Transcripción` that
  enters the RAG (the patient's historia clínica navegable,
  per ADR-003). The contract is provider-agnostic: any speech-to-text
  service that can be wrapped by an adapter fits.

  ## Input

  `transcribe/2` receives the audio as a binary. Options:

  - `:content_type` — the MIME type of the audio (for example
    `"audio/webm"`). Adapters need it to label the upload; without it they
    return `{:error, :missing_content_type}`.
  - `:language` — the language hint, `"es"` by default.

  ## Output

  `transcription()` is a map with `text` (the full transcript), `language`
  (detected or hinted, may be `nil`), `duration` (seconds, may be `nil`) and
  `segments`: `%{start, end, text, speaker}` for time-anchored citations in
  the RAG. `speaker` is a zero-based integer when the provider separates
  speakers (diarization) and `nil` otherwise.

  Adapters never raise and never log audio or transcript text. Failures are
  `{:error, {:http_status, status}}`, `{:error, :timeout}`,
  `{:error, {:transport, reason}}` or `{:error, :invalid_response}`.

  ## Adapters

  - `Alethea.AI.Whisper.Deepgram` — Deepgram `/v1/listen`, with speakers.
  - `Alethea.AI.Whisper.OpenAICompatible` — any `/audio/transcriptions`
    endpoint (OpenAI, Groq, a local Whisper server), without speakers.
  - `Alethea.AI.Whisper.Fake` — empty transcription for tests.
  - `Alethea.AI.Whisper.Disabled` — the capability switched off.

  ## Adapter discovery

  Domain code dispatches through `Alethea.AI.whisper/0` (see
  `lib/alethea/ai.ex`), which reads `config :alethea, :ai_whisper`.
  The default in `:test` env is `Alethea.AI.Whisper.Fake`; `:dev` and
  `:prod` are wired by `runtime_config/1` from `config/runtime.exs`
  (see `docs/features/transcription-providers.md`).
  """

  @typedoc "A timestamped segment of a transcription, suitable for time-anchored citations in the RAG."
  @type segment :: %{
          start: number(),
          end: number(),
          text: String.t(),
          speaker: non_neg_integer() | nil
        }

  @typedoc "The full transcription of a grabación."
  @type transcription :: %{
          text: String.t(),
          language: String.t() | nil,
          duration: number() | nil,
          segments: [segment()]
        }

  @typedoc "Raw audio bytes."
  @type audio :: binary()

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

  @default_receive_timeout "600000"

  @doc """
  Builds the `:alethea` application config for transcription from an
  environment map (normally `System.get_env/0`).

  Returns a list of `{key, value}` entries for `config :alethea, key, value`.
  `WHISPER_ENABLED` unset or `false` wires `Alethea.AI.Whisper.Disabled`;
  `true` requires `TRANSCRIPTION_PROVIDER` (`deepgram` or
  `openai_compatible`) and that provider's settings. Missing or invalid
  values raise; messages never echo a value.
  """
  @spec runtime_config(%{optional(String.t()) => String.t()}) :: [{atom(), term()}]
  def runtime_config(env) when is_map(env) do
    case Map.get(env, "WHISPER_ENABLED") do
      value when value in [nil, "false"] ->
        [ai_whisper: Alethea.AI.Whisper.Disabled]

      "true" ->
        provider_config(env)

      _other ->
        raise "environment variable WHISPER_ENABLED must be exactly true or false."
    end
  end

  defp provider_config(env) do
    hint = "It is required while WHISPER_ENABLED=true."
    receive_timeout = positive_integer_env(env, "WHISPER_RECEIVE_TIMEOUT_MS")

    case required_env(env, "TRANSCRIPTION_PROVIDER", hint) do
      "deepgram" ->
        adapter = Alethea.AI.Whisper.Deepgram

        [
          {:ai_whisper, adapter},
          {adapter,
           [
             api_key:
               required_env(env, "DEEPGRAM_API_KEY", "It is required by the deepgram provider."),
             model: optional_env(env, "DEEPGRAM_MODEL") || "nova-3",
             base_url: optional_env(env, "DEEPGRAM_BASE_URL") || "https://api.deepgram.com",
             receive_timeout: receive_timeout
           ]}
        ]

      "openai_compatible" ->
        adapter = Alethea.AI.Whisper.OpenAICompatible

        [
          {:ai_whisper, adapter},
          {adapter,
           [
             endpoint_url:
               required_env(
                 env,
                 "WHISPER_ENDPOINT_URL",
                 "It is required by the openai_compatible provider."
               ),
             api_key: optional_env(env, "WHISPER_API_KEY"),
             model: optional_env(env, "WHISPER_MODEL") || "whisper-1",
             receive_timeout: receive_timeout
           ]}
        ]

      _other ->
        raise "environment variable TRANSCRIPTION_PROVIDER must be deepgram or openai_compatible."
    end
  end

  # A blank value counts as missing; values are trimmed because they carry
  # credentials pasted from dashboards.
  defp optional_env(env, name) do
    case Map.get(env, name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  defp required_env(env, name, hint) do
    optional_env(env, name) || raise "environment variable #{name} is missing or empty. #{hint}"
  end

  defp positive_integer_env(env, name) do
    case Integer.parse(Map.get(env, name, @default_receive_timeout)) do
      {value, ""} when value > 0 -> value
      _other -> raise "environment variable #{name} must be a positive integer."
    end
  end
end
