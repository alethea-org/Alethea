defmodule Alethea.Jobs.TelegramBurstReplyWorker do
  @moduledoc """
  Generates exactly one reply for a patient's Telegram message burst
  (#391, S2 — inert: no production caller arms this yet, see S3).

  ## Debounce (R1, design AD1)

  `arm/1` schedules (or replaces) one job per patient, `@window_seconds`
  in the future. Uniqueness is scoped to **scheduled** jobs only
  (`states: :scheduled`), not the Oban default (which also includes
  `executing` and `completed`): a completed job must never block the
  next burst from arming, and a newer inbound while this job is
  executing must still schedule a fresh one (R1 "inbound during
  execution"). `replace: [scheduled: [:scheduled_at]]` is declared on
  the worker itself (not at each call site) so no caller can repeat
  the `scheduled_at` misplacement already fixed once in
  `TelegramMessageWorker` (see its `schedule_telegram_session_timeout/4`
  moduledoc).

  A literal copy of `AletheaJobs.SessionTimeoutWorker`'s
  `unique: [fields: [:args], period: :infinity]` would be unsafe here:
  its default `states` include `executing` and `completed`, so a
  completed burst job would block every later burst for the same
  patient forever.

  ## Save transaction (R2, R3, R6, R11, AD5, AD6, AD9)

  `perform/1` resolves the patient, lists every burst member
  (`Clinical.list_burst_members/1`), and — if any exist — generates one
  reply (`JournalingReply.generate_burst/2`) and saves it in a single
  transaction:

    1. Lock the patient's conversation (`Clinical.lock_patient_conversation!/1`,
       design AD6) — serializes against the crisis transaction.
    2. Save the reply, anchored to the newest member.
    3. Supersede any still-`pending` reply this burst absorbs
       (`Clinical.supersede_absorbed/1`, design AD5) — its count must
       equal the number of absorbed ids, or the transaction is stale.
    4. Cover every member (`Clinical.cover_members/3`) — its count must
       equal the number of members, or the transaction is stale.
    5. Check no inbound is left uncovered (`Clinical.uncovered_inbound?/1`,
       design R3) — a newer inbound arrived during generation.
    6. Save the AI diagnosis anchored to the newest member.
    7. Enqueue the delivery job INSIDE this transaction (design AD9):
       a crash before commit leaves nothing to resume; a crash after
       commit but before the job is visible cannot happen, because the
       enqueue is part of the same commit.

  Any staleness (`:coverage_lost`, `:stale`) or a lost race on the
  reply's own uniqueness (`:reply_already_exists`) rolls back
  everything — no reply row, no diagnosis, no delivery job (R3, AD3)
  — and re-arms the job itself (AD4): that re-arm is idempotent
  through AD1, so if the newer inbound already armed a job, this only
  replaces `scheduled_at`.

  ## Exhausted generation (#395)

  `perform/1` reuses the newest member's persisted reply when one exists
  (#390's "one logical reply per inbound" applied to a burst): a
  re-execution delivers what the clinical record holds instead of
  generating again, and never races the reply's unique index.

  A generation that keeps failing is retried by Oban up to
  `max_attempts`. Once that budget is exhausted — and only then — the
  worker persists ONE fixed `Alethea.Telegram.GenerationFailureNotice`
  for the whole burst, in the same transaction shape as a generated
  reply (coverage + PHI-safe failure metadata + delivery enqueue, AD9),
  so the patient is not left waiting and never receives an unconfirmed
  claim that the message was recorded. Generation exhaustion is NOT an
  outbound transport failure: it writes no outbound dead-letter. Because
  the notice is an ordinary pending reply, a newer inbound invalidates
  it under the same coverage/claim rules as a generated reply.
  """

  use Oban.Worker,
    queue: :telegram_inbound,
    max_attempts: 3,
    unique: [keys: [:patient_id], period: :infinity, states: :scheduled],
    replace: [scheduled: [:scheduled_at]]

  require Logger

  alias Alethea.{Clinical, Repo}
  alias Alethea.Clinical.{Message, SessionManager}
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Telegram.{GenerationFailureNotice, JournalingReply}
  alias AletheaJobs.SafeReason

  @window_seconds 45

  @doc """
  Arms (or renews) the single scheduled burst job for the patient
  identified by `args.patient_id`, `@window_seconds` from now (R1).

  `args` MUST carry `patient_id` (the foundation patient's id — the
  identity the uniqueness key and `perform/1`'s mismatch guard key on),
  `chat_id`, and `chat_id_hash` (carried through so `perform/1` can
  enqueue delivery without a second lookup).
  """
  @spec arm(%{patient_id: binary(), chat_id: integer(), chat_id_hash: String.t()}) :: :ok
  def arm(%{patient_id: _, chat_id: _, chat_id_hash: _} = args) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    args
    |> new(scheduled_at: DateTime.add(now, @window_seconds, :second))
    |> Oban.insert!()

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    patient_id = fetch!(args, :patient_id)
    chat_id_hash = fetch!(args, :chat_id_hash)

    case FoundationAccounts.lookup_patient_by_chat_hash(chat_id_hash) do
      {:ok, %{id: ^patient_id} = foundation_patient} ->
        run(foundation_patient, args, job)

      _ ->
        # Unknown hash, or the hash now resolves to a different
        # patient than the one this job was armed for (re-bind race).
        # Nothing to generate; the arm that scheduled this job already
        # did its job.
        :ok
    end
  end

  defp run(foundation_patient, args, job) do
    case Clinical.list_burst_members(foundation_patient) do
      {:ok, []} ->
        :ok

      {:ok, members} ->
        case persisted_reply(members) do
          %Message{} = reply ->
            resume_persisted_reply(foundation_patient, reply, args)

          nil ->
            generate_and_save(foundation_patient, members, args, job)
        end

      {:error, reason} ->
        raise "TelegramBurstReplyWorker: failed to list burst members " <>
                "(reason=#{inspect(reason)})"
    end
  end

  # #395: the newest member's persisted reply is this burst's logical
  # outcome. A re-execution (Oban retry, overlapping job, replay) must
  # reuse it instead of generating again. Without this check a persisted
  # failure notice would be regenerated on every execution and never
  # delivered, because colliding with the reply's unique index only
  # re-arms this same job (#391's `:reply_already_exists` branch).
  defp persisted_reply([_ | _] = members) do
    {anchor, _text} = List.last(members)
    Clinical.get_telegram_reply(anchor.id)
  end

  # Re-establishes delivery of the persisted (decrypted) body, never a
  # regenerated or re-read configuration value. Only a still-`pending`
  # reply is re-established: one with an outcome already decided
  # (sent, in flight, ambiguous, failed, or superseded by a newer burst)
  # is never sent again.
  defp resume_persisted_reply(_foundation_patient, %Message{delivery_state: state}, _args)
       when state in ["sending", "sent", "ambiguous", "failed", "superseded"] do
    :ok
  end

  defp resume_persisted_reply(foundation_patient, %Message{} = reply, args) do
    case Clinical.telegram_reply_text(foundation_patient, reply) do
      {:ok, body} when is_binary(body) ->
        case insert_outbound_job(foundation_patient, reply, body, args) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            raise "TelegramBurstReplyWorker: failed to re-enqueue persisted reply " <>
                    "(reason=#{SafeReason.for_log(reason)})"
        end

      other ->
        raise "TelegramBurstReplyWorker: failed to read persisted reply " <>
                "(reason=#{SafeReason.for_log(other)})"
    end
  end

  defp generate_and_save(foundation_patient, members, args, job) do
    case JournalingReply.generate_burst(foundation_patient, members) do
      {:ok, chain_result} ->
        save_burst_reply(foundation_patient, members, chain_result, args)

      {:error, reason} ->
        handle_generation_error(reason, foundation_patient, members, args, job)
    end
  end

  # A transient generation failure is Oban's to retry (`max_attempts: 3`,
  # the budget the pre-#391 synchronous path used). Exhausting that
  # budget is terminal for generation and is kept DISTINCT from an
  # outbound transport failure: the patient gets one fixed, transparent
  # "service unavailable" notice through the normal persisted delivery
  # path, and no outbound dead-letter is written (#395).
  defp handle_generation_error(reason, foundation_patient, members, args, job) do
    if retries_exhausted?(job) do
      save_failure_notice(foundation_patient, members, args, reason, job)
    else
      raise "TelegramBurstReplyWorker: PhiWorker error: #{SafeReason.for_log(reason)}"
    end
  end

  defp retries_exhausted?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp retries_exhausted?(_job), do: false

  defp save_burst_reply(foundation_patient, members, chain_result, args) do
    {anchor, _text} = List.last(members)
    member_ids = Enum.map(members, fn {message, _text} -> message.id end)

    absorbed_reply_ids =
      members
      |> Enum.map(fn {message, _text} -> message.replied_by_message_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    foundation_patient
    |> run_save_transaction(anchor, absorbed_reply_ids, member_ids, chain_result, args)
    |> case do
      {:ok, _reply} ->
        :ok

      {:error, reason} when reason in [:stale, :coverage_lost, :reply_already_exists] ->
        arm(args)
        :ok

      {:error, reason} ->
        # PHI hygiene (matches `TelegramMessageWorker`'s crisis/safe-path
        # raises): a diagnosis-save failure's `{:error, reason}` can be
        # an `%Ecto.Changeset{}` whose `changes` carries the plaintext
        # AI reply. `inspect/1` must never render it directly —
        # `SafeReason.for_log/1` surfaces only the failed field keys (or
        # the raw reason for a non-changeset error).
        raise "TelegramBurstReplyWorker: failed to save burst reply " <>
                "(reason=#{SafeReason.for_log(reason)})"
    end
  end

  # #395: the generation retry budget is exhausted. Persist ONE fixed
  # notice for the whole burst through the ordinary reply path, so the
  # existing coverage, dedup, supersession, and delivery rules apply
  # unchanged, and record the failure PHI-safely on the reply's
  # diagnosis (never in an outbound dead-letter).
  defp save_failure_notice(foundation_patient, members, args, generation_reason, job) do
    {anchor, _text} = List.last(members)
    member_ids = Enum.map(members, fn {message, _text} -> message.id end)

    absorbed_reply_ids =
      members
      |> Enum.map(fn {message, _text} -> message.replied_by_message_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # The recording clause is selected by the persistence predicate, not
    # hardcoded: the members were read back from storage, so recording is
    # confirmed here, and the notice may say so (#395 criteria 2-3).
    notice_text = GenerationFailureNotice.text(recorded?: persistence_confirmed?(members))

    # PHI-safe failure metadata: the reason is rendered by
    # `SafeReason.for_log/1` (field keys for a changeset, the raw term
    # otherwise) and the counts are integers. No patient text, no
    # chat id, no reply body.
    metadata = %{
      outcome: "generation_unavailable",
      reason: SafeReason.for_log(generation_reason),
      attempts: job_attempts(job),
      covered_messages: length(member_ids)
    }

    result =
      run_failure_transaction(
        foundation_patient,
        anchor,
        absorbed_reply_ids,
        member_ids,
        notice_text,
        metadata,
        args
      )

    case result do
      {:ok, _reply} ->
        Logger.warning(
          "TelegramBurstReplyWorker: generation retries exhausted, failure notice persisted " <>
            "(reason=#{metadata.reason}, attempts=#{metadata.attempts}, " <>
            "covered_messages=#{metadata.covered_messages})"
        )

        :ok

      {:error, :reply_already_exists} ->
        # A concurrent execution won the race and persisted this burst's
        # logical outcome. Deliver that one, never a second notice.
        resume_persisted_reply(foundation_patient, fetch_winning_reply!(anchor.id), args)

      {:error, reason} when reason in [:stale, :coverage_lost] ->
        # A newer inbound arrived while the notice was being saved: it
        # must not receive a stale notice. Re-arming lets the next burst
        # answer everything, notice included (#395 criterion 5).
        arm(args)
        :ok

      {:error, reason} ->
        raise "TelegramBurstReplyWorker: failed to persist generation failure notice " <>
                "(reason=#{SafeReason.for_log(reason)}, " <>
                "covered_messages=#{length(member_ids)})"
    end
  end

  # Mirrors `run_save_transaction/6`: the notice row, its coverage, its
  # PHI-safe failure metadata, and the delivery job commit together (AD9).
  # A persistence failure therefore leaves no notice to deliver — the
  # patient can never receive a recording claim that was not persisted
  # (#395 criteria 2-3).
  defp run_failure_transaction(
         foundation_patient,
         anchor,
         absorbed_reply_ids,
         member_ids,
         notice_text,
         metadata,
         args
       ) do
    Repo.transaction(fn ->
      legacy_patient = legacy_patient!(foundation_patient)
      :ok = Clinical.lock_patient_conversation!(legacy_patient.id)
      session_id = anchor.session_id || open_session_id(legacy_patient)

      with {:ok, reply} <-
             Clinical.save_telegram_reply(
               foundation_patient,
               notice_text,
               "elicited",
               anchor.id,
               session_id
             ),
           :ok <-
             assert_count(
               Clinical.supersede_absorbed(absorbed_reply_ids),
               length(absorbed_reply_ids)
             ),
           :ok <-
             assert_count(
               Clinical.cover_members(member_ids, reply.id, absorbed_reply_ids),
               length(member_ids)
             ),
           false <- Clinical.uncovered_inbound?(legacy_patient.id),
           {:ok, _diagnosis} <-
             Clinical.save_ai_diagnosis(anchor.id, %{
               response: notice_text,
               model_version: GenerationFailureNotice.model_version(),
               extracted_emotions: metadata
             }),
           {:ok, _job} <- insert_outbound_job(foundation_patient, reply, notice_text, args) do
        reply
      else
        true -> Repo.rollback(:stale)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # #395 criteria 2-3: the notice may assert recording only when its
  # inbounds are confirmed persisted rows. Here they always are — they
  # were read back from storage by `list_burst_members/1` — but the copy
  # is still selected through this predicate so a caller that cannot
  # confirm persistence gets the variant that claims nothing.
  defp persistence_confirmed?([_ | _] = members) do
    Enum.all?(members, fn {message, _text} -> is_binary(message.id) end)
  end

  defp persistence_confirmed?(_members), do: false

  defp job_attempts(%Oban.Job{attempt: attempt}) when is_integer(attempt), do: attempt
  defp job_attempts(_job), do: 1

  defp fetch_winning_reply!(anchor_id) do
    case Clinical.get_telegram_reply(anchor_id) do
      %Message{} = reply ->
        reply

      nil ->
        raise "TelegramBurstReplyWorker: reply reported as existing but not found"
    end
  end

  defp run_save_transaction(
         foundation_patient,
         anchor,
         absorbed_reply_ids,
         member_ids,
         chain_result,
         args
       ) do
    Repo.transaction(fn ->
      legacy_patient = legacy_patient!(foundation_patient)
      :ok = Clinical.lock_patient_conversation!(legacy_patient.id)
      session_id = anchor.session_id || open_session_id(legacy_patient)

      with {:ok, reply} <-
             Clinical.save_telegram_reply(
               foundation_patient,
               chain_result.response,
               "elicited",
               anchor.id,
               session_id
             ),
           :ok <-
             assert_count(
               Clinical.supersede_absorbed(absorbed_reply_ids),
               length(absorbed_reply_ids)
             ),
           :ok <-
             assert_count(
               Clinical.cover_members(member_ids, reply.id, absorbed_reply_ids),
               length(member_ids)
             ),
           false <- Clinical.uncovered_inbound?(legacy_patient.id),
           {:ok, _diagnosis} <- Clinical.save_ai_diagnosis(anchor.id, chain_result),
           {:ok, _job} <-
             insert_outbound_job(foundation_patient, reply, chain_result.response, args) do
        reply
      else
        true -> Repo.rollback(:stale)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp legacy_patient!(foundation_patient) do
    case FoundationAccounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} ->
        legacy_patient

      other ->
        raise "TelegramBurstReplyWorker: failed to resolve legacy patient " <>
                "(reason=#{inspect(other)})"
    end
  end

  defp open_session_id(legacy_patient) do
    {:ok, session} = SessionManager.current_open_session(legacy_patient.id)
    session.id
  end

  defp assert_count(count, count), do: :ok
  defp assert_count(_count, _expected), do: {:error, :coverage_lost}

  # Mirrors `TelegramMessageWorker.enqueue_outbound/6`'s `:safe`-lane
  # shape exactly (queue, priority, and the `message_id`-keyed
  # uniqueness that collapses a repeated enqueue of the same reply's
  # delivery onto the still-live job) — design's citation
  # `telegram_message_worker.ex:617-620`.
  defp insert_outbound_job(foundation_patient, reply, body, args) do
    new_args = %{
      chat_id_hash: fetch!(args, :chat_id_hash),
      chat_id: fetch!(args, :chat_id),
      message_id: reply.id,
      body: body,
      lane: :safe,
      priority: 9,
      patient_id: foundation_patient.id
    }

    job_opts = [
      queue: :telegram_outbound,
      priority: 9,
      unique: [keys: [:message_id], period: :infinity, states: :incomplete]
    ]

    new_args
    |> TelegramOutboundWorker.new(job_opts)
    |> Oban.insert()
  end

  defp fetch!(args, key) do
    Map.get(args, Atom.to_string(key)) || Map.fetch!(args, key)
  end
end
