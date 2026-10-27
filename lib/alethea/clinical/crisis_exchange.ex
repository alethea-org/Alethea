defmodule Alethea.Clinical.CrisisExchange do
  @moduledoc """
  Identification and neutralization of crisis exchanges inside the
  journaling context (#399).

  ## Decision (issue #399)

  A crisis exchange — the inbound that triggered the crisis plus the
  `crisis_bypass` reply the crisis path answered it with — is **replaced
  by one neutral placeholder turn** whenever conversation history
  (`Alethea.Clinical.list_conversation_turns/3`) or the running-summary
  window (`Alethea.Clinical.RunningSummary.window_turns/3`) is assembled
  for a model. Neither the patient's triggering words nor the crisis
  copy ever reach the conversational model; the placeholder keeps the
  continuity that *an* exchange happened and was handled, without
  exposing its content. This is consistent with the interim mitigation
  already in `Alethea.AI.RunningSummaryValidator` (crisis copy is never
  a valid summary fact).

  Exactly one placeholder turn is emitted per exchange, positioned at
  the earliest member visible in the fetched rows (normally the
  triggering inbound). The crisis path itself, the crisis copy and the
  crisis authority are out of scope (#389) and unchanged: this module
  only shapes what ordinary journaling generation and summarization see.

  Behavior change vs. the previous rule (crisis exchanges were included
  verbatim): clinical sign-off tracked in issue #399.

  ## Identification rule (one rule, three signals)

  A `messages` row belongs to a crisis exchange when any of:

    1. it is the `crisis_bypass` outbound reply
       (`behavior_type == "crisis_bypass"`);
    2. it is the triggering inbound, marked at classification time via
       `risk_signal["category"] == "confirmed_crisis"` — the audit is
       persisted by `TelegramMessageWorker` **before** the crisis reply
       transaction, so the trigger is identifiable even while its reply
       is not yet persisted (the #399 detection gap);
    3. a `crisis_bypass` reply points at it through
       `reply_to_message_id` — the fallback for rows persisted before
       the `risk_signal` migration (`20261009024315`).

  Residual gap: an inbound whose risk audit was never persisted (the
  job died between the inbound save and the audit write) and whose
  reply was never persisted either is indistinguishable from an
  ordinary message and is treated as one. Both writes happen inside
  the same `perform/1`, so the window is bounded by one crashed
  execution.

  The same rule feeds the running-summary cadence count
  (`exclude_members/1`), so history content and cadence use one
  population (#399 acceptance criteria).

  ## Placeholder

  `placeholder_turn/0` returns the synthetic
  `Alethea.Clinical.conversation_turn()` substituted for the exchange.
  It is static, content-free and identical for every patient; it passes
  through `Alethea.AI.Sanitizer` unchanged.
  """

  import Ecto.Query

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Repo

  @crisis_reply "crisis_bypass"
  @crisis_category "confirmed_crisis"
  @placeholder "[Intercambio gestionado por el protocolo de apoyo]"

  @doc "The static neutral text that stands in for a crisis exchange."
  @spec placeholder_text() :: String.t()
  def placeholder_text, do: @placeholder

  @doc "The synthetic turn substituted for a crisis exchange."
  @spec placeholder_turn() :: Clinical.conversation_turn()
  def placeholder_turn, do: %{role: :alethea, content: @placeholder}

  @doc """
  Converts fetched rows into model-facing conversation turns,
  collapsing every crisis exchange into `placeholder_turn/0`.

  Expects `rows` newest first (as fetched by both
  `Clinical.list_conversation_turns/3` and
  `RunningSummary.window_turns/3`) and returns turns oldest first.
  Members of a crisis exchange are never decrypted; ordinary rows are
  decrypted through `Alethea.Clinical.decrypt_message_content/2` and
  returned as-is, so callers that hand them to a model must still pass
  them through `Alethea.AI.Sanitizer`.
  """
  @spec turns([Message.t()], binary()) ::
          {:ok, [Clinical.conversation_turn()]} | {:error, term()}
  def turns(rows, dek) when is_list(rows) do
    trigger_ids = trigger_ids(rows)

    rows
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn message, {:ok, turns, seen} ->
      step(message, turns, seen, trigger_ids, dek)
    end)
    |> case do
      # The walk is chronological and prepends, so the accumulator is
      # newest first: reverse once to return oldest first.
      {:ok, turns, _seen} -> {:ok, Enum.reverse(turns)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes crisis-exchange members from an inbound-row population
  (the running-summary cadence count and target selection, #399).

  Written as the positive negation of the identification rule so it is
  `NULL`-safe on rows without a `risk_signal`.
  """
  @spec exclude_members(Ecto.Queryable.t()) :: Ecto.Queryable.t()
  def exclude_members(query) do
    from(m in query,
      where: m.behavior_type != ^@crisis_reply,
      where: fragment("?->>'category' IS DISTINCT FROM 'confirmed_crisis'", m.risk_signal),
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM messages r WHERE r.behavior_type = 'crisis_bypass' AND r.reply_to_message_id = ?)",
          m.id
        )
    )
  end

  defp step(message, turns, seen, trigger_ids, dek) do
    cond do
      not member?(message, trigger_ids) ->
        case Clinical.decrypt_message_content(message, dek) do
          {:ok, content} ->
            {:cont, {:ok, [%{role: role(message), content: content} | turns], seen}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      MapSet.member?(seen, exchange_key(message)) ->
        {:cont, {:ok, turns, seen}}

      true ->
        key = exchange_key(message)
        {:cont, {:ok, [placeholder_turn() | turns], MapSet.put(seen, key)}}
    end
  end

  # The identification rule, in Elixir form. `trigger_ids/1` resolves
  # the `reply_to_message_id` fallback for rows whose reply is not part
  # of the fetched set (the reply sorts after `current`, or outside the
  # window cap).
  defp member?(%Message{} = message, trigger_ids) do
    crisis_reply?(message) or crisis_trigger?(message) or MapSet.member?(trigger_ids, message.id)
  end

  defp crisis_reply?(%Message{behavior_type: @crisis_reply}), do: true
  defp crisis_reply?(%Message{}), do: false

  defp crisis_trigger?(%Message{risk_signal: %{"category" => @crisis_category}}), do: true
  defp crisis_trigger?(%Message{}), do: false

  # Both members of one exchange share the trigger's id: the reply
  # carries it in `reply_to_message_id`, the trigger IS it. An orphan
  # `crisis_bypass` reply (no provenance) folds into its own key.
  defp exchange_key(%Message{reply_to_message_id: trigger_id}) when is_binary(trigger_id),
    do: trigger_id

  defp exchange_key(%Message{} = message), do: message.id

  # Trigger inbounds identified only through their reply's provenance
  # (pre-`risk_signal` rows). Scoped to the fetched rows' ids, so the
  # reply itself may live outside the fetched set.
  defp trigger_ids([]), do: MapSet.new()

  defp trigger_ids(rows) do
    ids = Enum.map(rows, & &1.id)

    from(m in Message,
      where: m.behavior_type == ^@crisis_reply,
      where: not is_nil(m.reply_to_message_id),
      where: m.reply_to_message_id in ^ids,
      select: m.reply_to_message_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp role(%Message{direction: "inbound"}), do: :patient
  defp role(%Message{direction: "outbound"}), do: :alethea
end
