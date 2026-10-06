defmodule Alethea.Telegram.JournalingReply do
  @moduledoc """
  Produces the journaling reply for one inbound Telegram message (#392).

  This is the worker-side seam around the AI worker boundary
  (`Alethea.AI.PhiWorkerBehaviour`): everything the model is supplied
  with is assembled and sanitized here, before the boundary, so it is
  observable when the boundary is controlled.

  ## What the model is supplied with

    * the current turn, sanitized, exactly once;
    * up to 10 prior journaling messages, oldest first, each tagged
      `:patient` or `:alethea` and sanitized.

  Nothing else: no clinician records, no emotion scores, no other
  inferred clinical data.

  History is bounded at — and excludes — the inbound message being
  answered, so generating again for the same inbound reads the same
  snapshot.
  """

  require Logger

  alias Alethea.AI.Sanitizer
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Foundation.Accounts, as: FoundationAccounts

  @history_limit 10

  @type chain_result :: %{required(:response) => String.t(), optional(atom()) => term()}

  @doc """
  Generates the reply for `inbound`, whose plaintext is `text`.

  Returns `{:ok, chain_result}` with a non-empty `:response`, or
  `{:error, reason}` — `:empty_response` when the model returned no text,
  otherwise the reason reported by the AI worker.
  """
  @spec generate(FoundationAccounts.Patient.t(), Message.t(), String.t()) ::
          {:ok, chain_result()} | {:error, term()}
  def generate(foundation_patient, %Message{} = inbound, text) when is_binary(text) do
    request = %{
      message_id: inbound.id,
      sanitized_content: Sanitizer.sanitize(text),
      history: sanitized_history(foundation_patient, inbound)
    }

    case ai_worker().process(request) do
      {:ok, %{response: reply} = chain_result} when is_binary(reply) and reply != "" ->
        {:ok, chain_result}

      {:ok, %{response: _empty}} ->
        {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A history that cannot be loaded or decrypted degrades to an empty
  # one: the patient still gets a reply to the current turn, and nothing
  # undecryptable or unsanitized is supplied to the model.
  defp sanitized_history(foundation_patient, inbound) do
    with {:ok, legacy_patient} <- FoundationAccounts.legacy_patient(foundation_patient),
         {:ok, turns} <- Clinical.list_conversation_turns(legacy_patient, inbound, @history_limit) do
      Enum.map(turns, &%{role: &1.role, content: Sanitizer.sanitize(&1.content)})
    else
      _unavailable ->
        Logger.warning(
          "JournalingReply: conversation history unavailable, replying without it " <>
            "(message_id=#{inbound.id})"
        )

        []
    end
  end

  # Read at call time so tests can bind the boundary to
  # `Alethea.AI.PhiWorkerMock`.
  defp ai_worker, do: Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)
end
