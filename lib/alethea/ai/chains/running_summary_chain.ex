defmodule Alethea.AI.Chains.RunningSummaryChain do
  @moduledoc """
  Chain that produces the factual running summary (#394).

  Sends the model the static `Alethea.AI.RunningSummaryPrompt` as the
  system message and one user message that carries the previous summary
  (when there is one) and the conversation turns, each inside a data
  delimiter so the model treats them as material to summarize rather
  than as instructions.

  Callers pass material that is already sanitized (`PhiWorker.summarize/1`
  sanitizes again, idempotently). The result carries `truncated: true`
  when the model stopped at the token limit, so the caller can refuse a
  half-written summary.

  Telemetry (`[:alethea, :ai, :chain, :start | :stop]`) carries lengths,
  duration and success only. Summary text, turn text and failure reasons
  never reach it, and failures surface as the opaque `:generation_failed`.
  """
  @behaviour Alethea.AI.Chains.ChainBehaviour

  alias Alethea.AI.LLMConfig
  alias Alethea.AI.RunningSummaryPrompt
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @previous_delimiter "«RESUMEN PREVIO (datos)»"
  @turns_delimiter "«TURNOS (datos)»"

  @impl true
  def run(%{turns: turns} = params) when is_list(turns) do
    previous = Map.get(params, :previous_summary)
    user_block = user_block(turns, previous)

    :telemetry.execute(
      [:alethea, :ai, :chain, :start],
      %{chain: :running_summary, input_length: byte_size(user_block)},
      %{}
    )

    started = System.monotonic_time(:millisecond)
    result = generate(user_block)
    duration = System.monotonic_time(:millisecond) - started

    :telemetry.execute([:alethea, :ai, :chain, :stop], %{}, stop_metadata(result, duration))

    result
  end

  @impl true
  def run!(params) do
    {:ok, result} = run(params)
    result
  end

  @impl true
  def suggested_system_prompt, do: RunningSummaryPrompt.system_prompt()

  @impl true
  def suggested_max_tokens, do: 600

  @impl true
  def supported_providers, do: [:local]

  defp generate(user_block) do
    with {:ok, _config, llm} <-
           LLMConfig.get_and_build(:running_summary, max_tokens: suggested_max_tokens()),
         {:ok, chain} <- run_chain(llm, user_block) do
      %Message{content: content} = message = chain.last_message
      {:ok, %{summary: content, truncated: message.status == :length}}
    else
      _ -> {:error, :generation_failed}
    end
  end

  defp run_chain(llm, user_block) do
    messages = [
      Message.new_system!(RunningSummaryPrompt.system_prompt()),
      Message.new_user!(user_block)
    ]

    %{llm: llm, verbose: false}
    |> LLMChain.new!()
    |> LLMChain.add_messages(messages)
    |> LLMChain.run()
    |> case do
      {:ok, chain} -> {:ok, chain}
      _error -> :error
    end
  end

  defp user_block(turns, previous) do
    turns_text = Enum.map_join(turns, "\n", &turn_line/1)

    case previous do
      previous when is_binary(previous) and previous != "" ->
        "#{@previous_delimiter}\n#{strip_delimiters(previous)}\n\n#{@turns_delimiter}\n#{turns_text}"

      _none ->
        "#{@turns_delimiter}\n#{turns_text}"
    end
  end

  # Each turn is flattened to a single line, and the delimiter marks are
  # stripped from all material, so patient text can never forge an
  # `Alethea:` line or open a new data block.
  defp turn_line(%{role: :patient, content: content}), do: "Persona: " <> one_line(content)
  defp turn_line(%{role: :alethea, content: content}), do: "Alethea: " <> one_line(content)

  defp one_line(content), do: content |> String.replace(~r/\R/u, " ") |> strip_delimiters()

  defp strip_delimiters(text), do: String.replace(text, ["«", "»"], "")

  defp stop_metadata({:ok, %{summary: summary}}, duration),
    do: %{
      chain: :running_summary,
      duration_ms: duration,
      success: true,
      summary_length: byte_size(summary)
    }

  defp stop_metadata({:error, _}, duration),
    do: %{chain: :running_summary, duration_ms: duration, success: false}
end
