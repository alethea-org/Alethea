# AI Adapters Foundation Specification

## Purpose

Defines the stable behaviour interfaces for the three AI integrations of Alethea: the LLM (ADR-001), embeddings (ADR-002), and Whisper transcription. These behaviours are the **swap point** that lets the system change provider (Groq → OpenAI, HF → self-hosted, etc.) by changing the adapter implementation, not the domain code.

This spec covers the interface only. Concrete implementations (`Alethea.AI.LLM.Groq`, `Alethea.AI.Embeddings.HF`, `Alethea.AI.Whisper.Groq`) are scoped to future changes: `ai-llm-groq-foundation`, `ai-embeddings-hf-foundation`, `ai-whisper-groq-foundation`.

## Requirements

### Requirement: LLM Behaviour

The system MUST provide `Alethea.AI.LLM` as a behaviour module that declares the contract every LLM adapter MUST implement. The behaviour is responsible for conversational responses (the journaling channel) and for batch generation (resúmenes de brecha, psicometría batch).

```elixir
@callback chat(messages :: [message()], opts :: keyword()) :: {:ok, response()} | {:error, reason()}
@callback generate(prompt :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, reason()}
```

Typespecs: `message() :: %{role: :user | :assistant | :system, content: String.t()}` and `response() :: %{content: String.t(), usage: map() | nil, model: String.t()}`.

#### Scenario: A module that uses `@behaviour Alethea.AI.LLM` must define both callbacks

- GIVEN a module `Alethea.AI.LLM.Fake` does `use Alethea.AI.LLM`
- WHEN the module is compiled
- THEN the compiler emits a warning if either `chat/2` or `generate/2` is undefined
- AND if both are defined, compilation succeeds

#### Scenario: The behaviour module itself compiles and exports the expected callbacks

- GIVEN `Alethea.AI.LLM` is loaded
- WHEN `Alethea.AI.LLM.behaviour_info(:callbacks)` is called
- THEN the result is `[{:chat, 2}, {:generate, 2}]` (order may vary)

#### Scenario: Calling a callback on a missing implementation returns a structured error

- GIVEN no adapter is configured
- WHEN the application invokes `Alethea.AI.LLM.chat([], [])`
- THEN the call dispatches to whatever module is configured in application env (`config :alethea, :ai_llm, Alethea.AI.LLM.Fake`)
- AND if the configured module does not implement `chat/2`, the system has a sensible default behavior (covered by the future adapter change; this spec only requires the behaviour to exist)

### Requirement: Embeddings Behaviour

The system MUST provide `Alethea.AI.Embeddings` as a behaviour module that declares the contract every embeddings adapter MUST implement. The behaviour is responsible for turning text into vectors for the RAG.

```elixir
@callback embed(text :: String.t() | [String.t()], opts :: keyword()) ::
  {:ok, [float()]} | {:ok, [[float()]]} | {:error, reason()}
@callback model() :: String.t()
@callback dimensions() :: pos_integer()
```

The behaviour MUST declare that single-text input returns a single vector, and batch input returns a list of vectors in the same order.

#### Scenario: An adapter that uses `@behaviour Alethea.AI.Embeddings` must define all three callbacks

- GIVEN a module does `use Alethea.AI.Embeddings`
- WHEN the module is compiled
- THEN the compiler emits a warning if `embed/2`, `model/0`, or `dimensions/0` is undefined

#### Scenario: The behaviour module compiles and declares its callbacks

- GIVEN `Alethea.AI.Embeddings` is loaded
- WHEN `Alethea.AI.Embeddings.behaviour_info(:callbacks)` is called
- THEN the result includes `{:embed, 2}`, `{:model, 0}`, `{:dimensions, 0}`

### Requirement: Whisper Behaviour

The system MUST provide `Alethea.AI.Whisper` as a behaviour module that declares the contract every transcription adapter MUST implement. The behaviour is responsible for turning audio of a sesión clínica into text that enters the RAG.

```elixir
@callback transcribe(audio :: binary() | FileName.t(), opts :: keyword()) ::
  {:ok, transcription()} | {:error, reason()}

@type transcription :: %{
  text: String.t(),
  segments: [%{start: number(), end: number(), text: String.t()}],
  language: String.t() | nil
}
```

The behaviour MUST declare that the input can be a raw audio binary or a file path.

#### Scenario: An adapter that uses `@behaviour Alethea.AI.Whisper` must define `transcribe/2`

- GIVEN a module does `use Alethea.AI.Whisper`
- WHEN the module is compiled
- THEN the compiler emits a warning if `transcribe/2` is undefined

#### Scenario: The behaviour module compiles and declares its callback

- GIVEN `Alethea.AI.Whisper` is loaded
- WHEN `Alethea.AI.Whisper.behaviour_info(:callbacks)` is called
- THEN the result is `[{:transcribe, 2}]`

### Requirement: Adapter Discovery Through Application Config

The system MUST allow the LLM/Embeddings/Whisper adapter to be selected at runtime via application configuration (`config :alethea, :ai_llm, MyAdapter`). This spec does NOT mandate any specific adapter — it requires the swap point to exist. The default for each adapter in `:test` env MUST be a `Fake` no-op adapter that returns `{:ok, default_value}` for all callbacks.

#### Scenario: Test env has Fake adapters configured

- GIVEN `config/test.exs` is loaded
- WHEN the application starts in `:test` env
- THEN `Application.get_env(:alethea, :ai_llm)` returns a module that implements `Alethea.AI.LLM`
- AND the same for `ai_embeddings` and `ai_whisper`

#### Scenario: A non-Fake adapter can be swapped in via config

- GIVEN a custom module `MyApp.MyLLM` implements `Alethea.AI.LLM`
- WHEN `config :alethea, :ai_llm, MyApp.MyLLM` is set
- THEN the next call to `Alethea.AI.LLM.chat/2` dispatches to `MyApp.MyLLM` (covered by the future adapter change; this spec only requires the config key to exist)
