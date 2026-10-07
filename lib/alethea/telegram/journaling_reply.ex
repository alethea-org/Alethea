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

  ## What may come back

  The generated text is validated with `Alethea.AI.JournalingOutputGuard`
  before it is returned. Blocked text never leaves this module: the
  result carries a neutral exploratory fallback from
  `Alethea.Telegram.JournalingFallback` instead, with `:guardrail` set
  to the block reason and `:model_version` set to
  `"journaling-fallback"`.

  A reply the AI worker marks `truncated: true` (the model stopped at
  the length limit) is withheld the same way, with `guardrail:
  :incomplete`: reply length is bounded by generation configuration, and
  a sentence cut off by that bound is not delivered as if it were whole.

  History is bounded at — and excludes — the inbound message being
  answered, so generating again for the same inbound reads the same
  snapshot.
  """

  require Logger

  alias Alethea.AI.{JournalingOutputGuard, Sanitizer}
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Telegram.JournalingFallback

  @history_limit 10
  @fallback_model_version "journaling-fallback"

  @type chain_result :: %{required(:response) => String.t(), optional(atom()) => term()}

  @doc """
  Generates the reply for `inbound`, whose plaintext is `text`.

  A thin delegate to `generate_burst/2` for the single-member case
  (#391): `generate(p, inbound, text)` is
  `generate_burst(p, [{inbound, text}])`.

  Returns `{:ok, chain_result}` with a non-empty `:response`, or
  `{:error, reason}` — `:empty_response` when the model returned no text,
  otherwise the reason reported by the AI worker.
  """
  @spec generate(FoundationAccounts.Patient.t(), Message.t(), String.t()) ::
          {:ok, chain_result()} | {:error, term()}
  def generate(foundation_patient, %Message{} = inbound, text) when is_binary(text) do
    generate_burst(foundation_patient, [{inbound, text}])
  end

  @doc """
  Generates one reply covering every `members` of a Telegram burst
  (#391), each a `{inbound, text}` pair.

  Every member's sanitized text is supplied exactly once, in the
  order given, joined by a blank line into the current turn
  (`sanitized_content`) — design AD8: the single-string contract needs
  no change to `Alethea.AI.PhiWorkerBehaviour`. The anchor — the
  reply's `message_id`, and the message the guard/fallback attach to —
  is the newest member, `List.last(members)`.

  History is bounded at the earliest member (`List.first(members)`),
  so no member of the burst ever appears in its own history: a burst
  job retried after a rollback reads the same snapshot.

  Returns `{:ok, chain_result}` with a non-empty `:response`, or
  `{:error, reason}` — `:empty_response` when the model returned no
  text, otherwise the reason reported by the AI worker.
  """
  @spec generate_burst(FoundationAccounts.Patient.t(), [{Message.t(), String.t()}, ...]) ::
          {:ok, chain_result()} | {:error, term()}
  def generate_burst(foundation_patient, [_ | _] = members) do
    {earliest, _text} = List.first(members)
    {anchor, _text} = List.last(members)

    sanitized_content =
      members
      |> Enum.map(fn {_message, text} -> Sanitizer.sanitize(text) end)
      |> Enum.join("\n\n")

    request = %{
      message_id: anchor.id,
      sanitized_content: sanitized_content,
      history: sanitized_history(foundation_patient, earliest)
    }

    case ai_worker().process(request) do
      {:ok, %{response: reply} = chain_result} when is_binary(reply) and reply != "" ->
        {:ok, guard(chain_result, anchor)}

      {:ok, %{response: _empty}} ->
        {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The generated text is checked before the caller can persist or
  # deliver it. A blocked reply is discarded here: the returned result
  # carries the fallback as `:response`, so neither the outbound message,
  # the delivery job, nor the AI record anchored to the inbound ever sees
  # the blocked text. `:model_version` is replaced because the fallback
  # was not written by the model.
  defp guard(chain_result, inbound) do
    case check(chain_result) do
      :ok ->
        chain_result

      {:blocked, reason} ->
        Logger.warning(
          "JournalingReply: generated reply blocked, fallback substituted " <>
            "(reason=#{reason}, message_id=#{inbound.id})"
        )

        chain_result
        |> Map.put(:response, JournalingFallback.for_inbound(inbound.id))
        |> Map.put(:model_version, @fallback_model_version)
        |> Map.put(:guardrail, reason)
    end
  end

  # A reply the AI worker reports as cut off by the length limit is an
  # unfinished sentence. It is never trimmed into something that looks
  # complete; it is withheld like any other blocked reply.
  defp check(%{truncated: true}), do: {:blocked, :incomplete}
  defp check(%{response: reply}), do: JournalingOutputGuard.check(reply)

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
