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
  def run(%{sanitized_content: content, patient_context: ctx, message_id: msg_id}) do
    case LLMConfig.get_and_build(:guided_conversation) do
      {:ok, _config, llm} -> do_run(llm, content, ctx, msg_id)
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

  defp do_run(%OllamaChat{} = llm, content, ctx, msg_id) do
    system_msg = build_system_message(ctx)

    :telemetry.execute(
      [:alethea, :ai, :chain, :start],
      %{
        chain: :guided_conversation,
        content_length: byte_size(content)
      },
      %{}
    )

    start_time = System.monotonic_time(:millisecond)
    result = do_chain_run(llm, system_msg, content)
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

  defp do_run(llm, content, ctx, msg_id) do
    system_msg = build_system_message(ctx)

    :telemetry.execute(
      [:alethea, :ai, :chain, :start],
      %{
        chain: :guided_conversation,
        provider: :cloud
      },
      %{}
    )

    start_time = System.monotonic_time(:millisecond)
    result = do_chain_run(llm, system_msg, content)
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{duration_ms: duration}, %{
      chain: :guided_conversation,
      provider: :cloud,
      success: match?({:ok, _}, result)
    })

    result |> wrap_result(msg_id)
  end

  defp do_chain_run(llm, system_msg, content) do
    %{llm: llm, verbose: false}
    |> LLMChain.new!()
    |> LLMChain.add_message(Message.new_system!(system_msg))
    |> LLMChain.add_message(Message.new_user!(content))
    |> LLMChain.run()
    |> case do
      {:ok, chain} -> {:ok, chain.last_message.content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_system_message(context),
    do: "#{default_system_prompt()}\n\nContexto del paciente: #{context}"

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
