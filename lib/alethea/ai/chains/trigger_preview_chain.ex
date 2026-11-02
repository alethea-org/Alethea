defmodule Alethea.AI.Chains.TriggerPreviewChain do
  @moduledoc """
  Drafts a patient-facing proactive message in the bot's clinically neutral voice,
  in Spanish, from a therapist's instruction (Issue #440, S2).

  Sanitizes the instruction at the boundary via `Alethea.AI.Sanitizer`.
  Runs through `LLMConfig.get_and_build(:trigger_preview, ...)`.
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.LLMConfig
  alias Alethea.AI.Sanitizer
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{instruction: instruction}) when is_binary(instruction) do
    sanitized = Sanitizer.sanitize(instruction)
    prompt = build_user_message(sanitized)

    case LLMConfig.get_and_build(:trigger_preview, max_tokens: suggested_max_tokens()) do
      {:ok, _config, llm} ->
        execute_chain(llm, prompt)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(instruction) when is_binary(instruction) do
    run(%{instruction: instruction})
  end

  def run(_invalid), do: {:error, :invalid_instruction}

  @impl true
  def run!(params) do
    case run(params) do
      {:ok, result} -> result
      {:error, reason} -> raise "TriggerPreviewChain failed: #{inspect(reason)}"
    end
  end

  @doc """
  Pure prompt builder for the user message, applying boundary sanitization.
  """
  @spec build_prompt(String.t()) :: String.t()
  def build_prompt(instruction) when is_binary(instruction) do
    sanitized = Sanitizer.sanitize(instruction)
    build_user_message(sanitized)
  end

  defp build_user_message(sanitized) do
    "Instrucción del terapeuta:\n#{sanitized}"
  end

  @impl true
  def suggested_system_prompt do
    """
    Eres Alethea, un bot de acompañamiento clínico. Tu tarea es redactar un mensaje breve, cálido y clínicamente neutral para el paciente, en español, a partir de una instrucción dada por su terapeuta.
    El mensaje debe estar dirigido directamente al paciente, con tono empático y respetuoso.
    No uses lenguaje directivo, técnico ni autoritario.
    Devuelve ÚNICAMENTE el texto redactado para el paciente, sin preámbulos, sin comillas, sin explicaciones adicionales.
    """
  end

  @impl true
  def suggested_max_tokens, do: 256

  @impl true
  def supported_providers, do: [:local, :cloud]

  defp execute_chain(llm, user_message) do
    messages = [
      Message.new_system!(suggested_system_prompt()),
      Message.new_user!(user_message)
    ]

    %{llm: llm, verbose: false}
    |> LLMChain.new!()
    |> LLMChain.add_messages(messages)
    |> LLMChain.run()
    |> case do
      {:ok, chain} ->
        draft =
          chain.last_message
          |> Map.get(:content, "")
          |> to_string()
          |> String.trim()
          |> String.trim("\"")

        {:ok, %{draft: draft}}

      {:error, _chain, error} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
