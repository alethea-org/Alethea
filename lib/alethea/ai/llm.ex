defmodule Alethea.AI.LLM do
  @moduledoc """
  Behaviour contract for the LLM (large language model) integration.

  ## Why this behaviour exists (ADR-001)

  Per `openspec/adr/001-llm-en-groq.md`, every call to a language model
  in Alethea goes through a stable interface. Swapping providers
  (Phi-4-mini on Groq today, possibly Claude Sonnet tomorrow for crisis
  detection with higher sensitivity) means changing the adapter, not
  the domain code.

  The behaviour is intentionally minimal: two callbacks that cover
  conversational responses (the journaling channel) and batch generation
  (resúmenes de brecha, psicometría batch).

  ## Boundary with the legacy `Alethea.AI.*` namespace

  The legacy `Alethea.AI.LLMConfig` (`lib/alethea/ai/llm_config.ex`)
  remains the v1 configuration surface for LangChain chat models. The
  v2 behaviour here defines the **adapter** contract for the
  provider-agnostic `Alethea.AI.llm/0` discovery slot. They are
  parallel: the legacy config builds a LangChain chat model, this
  behaviour is the callback an adapter must implement.

  ## Adapter discovery

  Domain code dispatches through `Alethea.AI.llm/0` (see
  `lib/alethea/ai.ex`), which reads `config :alethea, :ai_llm`. The
  default in `:test` env is `Alethea.AI.LLM.Fake`.

  ## What concrete implementations are out of scope here

  - `Alethea.AI.LLM.Groq` → `ai-llm-groq-foundation`
  - `Alethea.AI.LLM.OpenAI` → not scoped yet
  """

  @typedoc "A single chat message. Roles follow the OpenAI / Groq convention."
  @type message :: %{role: :user | :assistant | :system, content: String.t()}

  @typedoc "The successful response shape. `usage` may be nil for adapters that don't track token counts."
  @type response :: %{content: String.t(), usage: map() | nil, model: String.t()}

  @typedoc "A provider-specific error reason. Adapters are free to return any term."
  @type reason :: term()

  @doc """
  Conversational completion. Returns a response map with the assistant's
  text, optional usage stats, and the model identifier that produced it.
  """
  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, response()} | {:error, reason()}

  @doc """
  Single-prompt batch generation (e.g., resúmenes de brecha, psicometría
  batch). Returns just the generated text — no message framing.
  """
  @callback generate(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, reason()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Alethea.AI.LLM
    end
  end
end
