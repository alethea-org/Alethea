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
      `:patient` or `:alethea` and sanitized;
    * the running summary, when a usable one exists (#394);
    * the approved text of at most one reactive trigger matched on the
      sanitized burst text (#448, `Alethea.Triggers.ReactiveMatch`),
      sanitized. When it is used, the result carries `:trigger_match`
      (`%{trigger_id, probability}`) so the caller can record the firing.

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

  alias Alethea.Accounts
  alias Alethea.AI.{JournalingOutputGuard, RunningSummaryValidator, Sanitizer}
  alias Alethea.Alerts.CrisisCopy
  alias Alethea.Clinical
  alias Alethea.Clinical.{Message, RunningSummary}
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Telegram.{JournalingFallback, TopicExploration}
  alias Alethea.Triggers.ReactiveMatch

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

    # #393 S3 (design §2, "legacy patient resolved once"): shared by
    # the history read and the exploration-state read below, instead
    # of each resolving it independently.
    legacy_patient = resolve_legacy_patient(foundation_patient)
    state = read_exploration_state(legacy_patient, earliest, anchor.session_id)

    sanitized_content =
      members
      |> Enum.map(fn {_message, text} -> Sanitizer.sanitize(text) end)
      |> Enum.join("\n\n")

    request = %{
      message_id: anchor.id,
      sanitized_content: sanitized_content,
      history: sanitized_history(legacy_patient, earliest),
      exploration_mode: TopicExploration.mode(state)
    }

    request = maybe_put_summary(request, foundation_patient, anchor)

    # #448: at most one reactive trigger, matched on the sanitized burst
    # text before generation; any matcher failure means no trigger.
    match = ReactiveMatch.find(legacy_patient, sanitized_content)
    request = maybe_put_trigger(request, match)

    guard_context =
      if is_binary(request[:trigger]) and request[:trigger] != "",
        do: :trigger,
        else: :journaling

    case ai_worker().process(request) do
      {:ok, %{response: reply} = chain_result} when is_binary(reply) and reply != "" ->
        chain_result
        |> finish_reply(reply, state, anchor, guard_context)
        |> maybe_put_trigger_match(match)

      {:ok, %{response: _empty}} ->
        {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # #393 S3 (design pipeline steps 6-8): the model's leading marker is
  # parsed and stripped BEFORE the guard ever sees the text — the
  # guard and persistence must never observe marker syntax (design
  # §1, AD2). A marker-only reply strips to `""` and is treated like
  # any other empty response. `TopicExploration.enforce/4` runs after
  # the guard (AD3): the guard's clinical-wording concern stays
  # separate from the exploration-count concern, so a guard fallback
  # can itself be substituted again by closing/acknowledgement copy.
  defp finish_reply(chain_result, raw_reply, state, anchor, guard_context) do
    {new_situation, text} = TopicExploration.parse_marker(raw_reply)

    case text do
      "" ->
        {:error, :empty_response}

      _non_empty ->
        guarded =
          chain_result
          |> Map.put(:response, text)
          |> guard(anchor, guard_context)

        {:ok, TopicExploration.enforce(guarded, state, new_situation, anchor.id)}
    end
  end

  # The generated text is checked before the caller can persist or
  # deliver it. A blocked reply is discarded here: the returned result
  # carries the fallback as `:response`, so neither the outbound message,
  # the delivery job, nor the AI record anchored to the inbound ever sees
  # the blocked text. `:model_version` is replaced because the fallback
  # was not written by the model.
  defp guard(chain_result, inbound, guard_context) do
    case check(chain_result, guard_context) do
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
  defp check(%{truncated: true}, _context), do: {:blocked, :incomplete}
  defp check(%{response: reply}, context), do: JournalingOutputGuard.check(reply, context)

  # A history that cannot be loaded or decrypted degrades to an empty
  # one: the patient still gets a reply to the current turn, and nothing
  # undecryptable or unsanitized is supplied to the model.
  defp sanitized_history(nil, _inbound), do: []

  defp sanitized_history(legacy_patient, inbound) do
    case Clinical.list_conversation_turns(legacy_patient, inbound, @history_limit) do
      {:ok, turns} ->
        Enum.map(turns, &%{role: &1.role, content: Sanitizer.sanitize(&1.content)})

      {:error, _reason} ->
        Logger.warning(
          "JournalingReply: conversation history unavailable, replying without it " <>
            "(message_id=#{inbound.id})"
        )

        []
    end
  end

  # #393 S3: resolved once, shared by `sanitized_history/2` and
  # `read_exploration_state/3`. `nil` when the foundation patient is
  # not linked, degrading both the same way `sanitized_history/2`
  # already degraded on its own lookup failure.
  defp resolve_legacy_patient(foundation_patient) do
    case FoundationAccounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} ->
        legacy_patient

      _unavailable ->
        Logger.warning("JournalingReply: legacy patient unavailable, replying without history")
        nil
    end
  end

  # A `nil` legacy patient (unlinked foundation patient) degrades to a
  # fresh stretch, the same default `Alethea.Clinical.exploration_state/3`
  # itself falls back to when it has nothing to read.
  defp read_exploration_state(nil, _current, _session_id),
    do: %{questions: 0, closing_invitation_sent: false}

  defp read_exploration_state(legacy_patient, current, session_id),
    do: Clinical.exploration_state(legacy_patient, current, session_id)

  # The running summary (#394) is attached only when a usable one exists:
  # a missing row stays silent (and unaudited), a rejected or unreadable
  # one degrades to a reply without it. It is validated against the
  # current crisis copy and sanitized like every other supplied text.
  defp maybe_put_summary(request, foundation_patient, anchor) do
    case load_summary(foundation_patient) do
      {:ok, summary} ->
        Map.put(request, :summary, Sanitizer.sanitize(summary))

      :none ->
        request

      :error ->
        Logger.warning(
          "JournalingReply: running summary unavailable, replying without it " <>
            "(message_id=#{anchor.id})"
        )

        request
    end
  end

  # The approved trigger text is professional-written data; it is sanitized
  # like every other supplied text before it reaches the AI worker.
  defp maybe_put_trigger(request, {:ok, {trigger, _probability}}),
    do: Map.put(request, :trigger, Sanitizer.sanitize(trigger.decrypted_approved_text))

  defp maybe_put_trigger(request, :none), do: request

  # The firing is recorded by the caller (in its save transaction) only when
  # the model's own reply is delivered: a reply replaced by a fallback
  # (guard block, truncation, exploration copy) never carried the trigger.
  defp maybe_put_trigger_match({:ok, %{model_version: @fallback_model_version}} = result, _),
    do: result

  defp maybe_put_trigger_match({:ok, result}, {:ok, {trigger, probability}}),
    do:
      {:ok, Map.put(result, :trigger_match, %{trigger_id: trigger.id, probability: probability})}

  defp maybe_put_trigger_match(result, _match), do: result

  defp load_summary(foundation_patient) do
    # Checked first: with a hosted reply provider the summary must not even
    # be read, let alone sent to the model (REQ-22), except under the
    # synthetic demo profile (see `RunningSummary.enabled?/0`).
    with true <- RunningSummary.enabled?() || :none,
         {:ok, legacy_patient} <- FoundationAccounts.legacy_patient(foundation_patient),
         %{} = patient <- Accounts.get_patient_with_professional(legacy_patient.id),
         true <- RunningSummary.exists?(patient) || :none,
         {:ok, summary} <- RunningSummary.load_usable(patient),
         :ok <- RunningSummaryValidator.validate(summary, CrisisCopy.reply_text(patient)) do
      {:ok, summary}
    else
      :none -> :none
      _unusable -> :error
    end
  end

  # Read at call time so tests can bind the boundary to
  # `Alethea.AI.PhiWorkerMock`.
  defp ai_worker, do: Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)
end
