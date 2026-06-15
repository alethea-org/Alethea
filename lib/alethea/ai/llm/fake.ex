defmodule Alethea.AI.LLM.Fake do
  @moduledoc """
  No-op LLM adapter for the `:test` and `:dev` environments.

  Implements the `Alethea.AI.LLM` behaviour with deterministic
  responses. It does not call any external service, does not hit the
  network, and is safe to use in tests, local development, and
  documentation examples.

  ## Why deterministic

  Tests that call into an LLM should not flake on real-API behaviour.
  The Fake returns the same content for the same input shape, so
  assertions in journaling, resúmenes-de-brecha, and psicometría
  features can be pinned.

  ## Production swap

  The production adapter is `Alethea.AI.LLM.Groq`, scoped to the
  `ai-llm-groq-foundation` change. The swap happens in
  `config :alethea, :ai_llm, Alethea.AI.LLM.Groq` — this module's
  surface stays stable, so domain code does not change.
  """

  use Alethea.AI.LLM

  @impl true
  def chat(_messages, _opts) do
    {:ok, fake_response()}
  end

  @impl true
  def generate(_prompt, _opts) do
    {:ok, fake_completion()}
  end

  defp fake_response do
    %{content: "fake-response", usage: nil, model: "fake-llm"}
  end

  defp fake_completion, do: "fake-completion"
end
