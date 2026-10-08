defmodule Alethea.AI.Chains.SafeRun do
  @moduledoc """
  Runs a LangChain `LLMChain` for the chains of the AI context and turns
  every failure into a small tagged reason that carries no clinical
  content (issue #402).

  ## Why the failure is rebuilt instead of passed through

  `LLMChain.run/1` reports a failure as `{:error, chain, %LangChainError{}}`.
  Nothing in that tuple is safe to hand to a caller:

    * the chain holds every message of the run, i.e. the patient's
      (sanitized, still clinical) text;
    * `LangChainError.message` is free text written by the chat model
      adapter. `OllamaChat` builds it from an HTTP status or an inspected
      transport error, but `ChatOpenAI` copies the provider's own error
      message, which may quote the request;
    * `LangChainError.original` is the wrapped exception or response
      (for example a `Jason.DecodeError` holding the raw response body).

  A caller that returns such a term from an Oban job persists it in
  `oban_jobs.errors` and logs it: clinical text at rest outside the
  patient-level encryption. So only the error `type` survives, and only
  when it has the shape of an identifier (`"timeout"`, `"overloaded"`,
  `"rate_limit_error"`, …): a provider chooses that string too, so a value
  that could hold prose is dropped rather than trusted.

  An exception raised by the run is reduced the same way, to its module:
  a `CaseClauseError` or `FunctionClauseError` message would print the
  offending term, which here is the request or the response.

  ## Reasons

    * `{:llm_run_failed, type}` — `type` is the identifier-shaped
      `LangChainError.type` as a string, `:untyped` when the error has no
      type, or `:unclassified` for any other error shape;
    * `{:llm_run_failed, {:raised, module}}` — the run raised `module`.

  `inspect/1` of a reason is safe for telemetry metadata and logs.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.LangChainError

  @type reason ::
          {:llm_run_failed, String.t() | :untyped | :unclassified | {:raised, module()}}

  # Long enough for the type codes of LangChain and of the providers,
  # short and restricted enough that it cannot hold a sentence.
  @type_shape ~r/\A[a-z][a-z0-9_.]{0,63}\z/

  @doc """
  Runs `chain` and returns `{:ok, chain}` or `{:error, reason}`, where
  `reason` never embeds the chain, a message or a provider payload.
  """
  @spec run(LLMChain.t()) :: {:ok, LLMChain.t()} | {:error, reason()}
  def run(%LLMChain{} = chain) do
    chain
    |> LLMChain.run()
    |> normalize()
  rescue
    exception -> {:error, {:llm_run_failed, {:raised, exception.__struct__}}}
  end

  @doc """
  Normalizes a `LLMChain.run/1` result. Exposed so the mapping can be
  specified without a model.
  """
  @spec normalize(term()) :: {:ok, LLMChain.t()} | {:error, reason()}
  def normalize({:ok, %LLMChain{} = chain}), do: {:ok, chain}
  def normalize({:error, %LLMChain{}, error}), do: {:error, reason(error)}
  def normalize({:error, error}), do: {:error, reason(error)}
  def normalize(_other), do: {:error, {:llm_run_failed, :unclassified}}

  defp reason(%LangChainError{type: nil}), do: {:llm_run_failed, :untyped}

  defp reason(%LangChainError{type: type}) when is_binary(type) do
    if Regex.match?(@type_shape, type) do
      {:llm_run_failed, type}
    else
      {:llm_run_failed, :unclassified}
    end
  end

  defp reason(_other), do: {:llm_run_failed, :unclassified}
end
