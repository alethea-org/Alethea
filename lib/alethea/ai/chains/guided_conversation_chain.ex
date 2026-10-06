defmodule Alethea.AI.Chains.GuidedConversationChain do
  @moduledoc """
  Chain de LangChain para conversación guiada con un LLM externo.

  Métricas de telemetry:
  - `[:alethea, :ai, :chain, :start]` - Inicio de chain
  - `[:alethea, :ai, :chain, :stop]` - Fin de chain con duración
  - `[:alethea, :ai, :llm, :call]` - Llamada al LLM
  - `[:alethea, :ai, :llm, :response]` - Respuesta del LLM
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.LLMConfig
  alias Alethea.AI.ChatModels.OllamaChat
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @impl true
  def run(%{sanitized_content: content, history: history, message_id: msg_id}) do
    case LLMConfig.get_and_build(:guided_conversation) do
      {:ok, _config, llm} -> do_run(llm, content, history, msg_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run!(params) do
    {:ok, result} = run(params)
    result
  end

  @impl true
  def suggested_system_prompt, do: default_system_prompt()

  @impl true
  def suggested_max_tokens, do: 512

  @impl true
  def supported_providers, do: [:local, :cloud]

  defp do_run(%OllamaChat{} = llm, content, history, msg_id) do
    :telemetry.execute(
      [:alethea, :ai, :chain, :start],
      %{
        chain: :guided_conversation,
        content_length: byte_size(content)
      },
      %{}
    )

    start_time = System.monotonic_time(:millisecond)
    result = do_chain_run(llm, history, content)
    duration = System.monotonic_time(:millisecond) - start_time

    metadata =
      case result do
        {:ok, response} ->
          %{
            chain: :guided_conversation,
            duration_ms: duration,
            success: true,
            response_length: byte_size(response)
          }

        {:error, reason} ->
          %{
            chain: :guided_conversation,
            duration_ms: duration,
            success: false,
            error: inspect(reason)
          }
      end

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, metadata)

    result |> wrap_result(msg_id)
  end

  defp do_run(llm, content, history, msg_id) do
    :telemetry.execute(
      [:alethea, :ai, :chain, :start],
      %{
        chain: :guided_conversation,
        provider: :cloud
      },
      %{}
    )

    start_time = System.monotonic_time(:millisecond)
    result = do_chain_run(llm, history, content)
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{duration_ms: duration}, %{
      chain: :guided_conversation,
      provider: :cloud,
      success: match?({:ok, _}, result)
    })

    result |> wrap_result(msg_id)
  end

  # Prior turns reach the model as distinct chat messages, never as one
  # flattened context block, so it cannot mistake its own earlier
  # questions for something the patient said.
  defp do_chain_run(llm, history, content) do
    messages =
      [Message.new_system!(default_system_prompt())] ++
        Enum.map(history, &turn_message/1) ++ [Message.new_user!(content)]

    %{llm: llm, verbose: false}
    |> LLMChain.new!()
    |> LLMChain.add_messages(messages)
    |> LLMChain.run()
    |> case do
      {:ok, chain} -> {:ok, chain.last_message.content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp turn_message(%{role: :patient, content: content}), do: Message.new_user!(content)
  defp turn_message(%{role: :alethea, content: content}), do: Message.new_assistant!(content)

  defp default_system_prompt,
    do: """
    Eres un asistente clínico de apoyo. Tu rol es escuchar y formular preguntas exploratorias.
    NO valides ni refutes los pensamientos del paciente sin instrucción explícita del terapeuta.
    Evita emitir diagnósticos o consejos médicos directos.
    """

  defp wrap_result({:ok, response}, msg_id),
    do:
      {:ok,
       %{
         response: response,
         source_message_id: msg_id,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}

  defp wrap_result({:error, _} = error, _msg_id), do: error
end
