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
  """

  use Oban.Worker,
    queue: :telegram_inbound,
    max_attempts: 3,
    unique: [keys: [:patient_id], period: :infinity, states: :scheduled],
    replace: [scheduled: [:scheduled_at]]

  alias Alethea.{Clinical, Repo}
  alias Alethea.Clinical.SessionManager
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Telegram.JournalingReply

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
  def perform(%Oban.Job{args: args}) do
    patient_id = fetch!(args, :patient_id)
    chat_id_hash = fetch!(args, :chat_id_hash)

    case FoundationAccounts.lookup_patient_by_chat_hash(chat_id_hash) do
      {:ok, %{id: ^patient_id} = foundation_patient} ->
        run(foundation_patient, args)

      _ ->
        # Unknown hash, or the hash now resolves to a different
        # patient than the one this job was armed for (re-bind race).
        # Nothing to generate; the arm that scheduled this job already
        # did its job.
        :ok
    end
  end

  defp run(foundation_patient, args) do
    case Clinical.list_burst_members(foundation_patient) do
      {:ok, []} ->
        :ok

      {:ok, members} ->
        generate_and_save(foundation_patient, members, args)

      {:error, reason} ->
        raise "TelegramBurstReplyWorker: failed to list burst members " <>
                "(reason=#{inspect(reason)})"
    end
  end

  defp generate_and_save(foundation_patient, members, args) do
    case JournalingReply.generate_burst(foundation_patient, members) do
      {:ok, chain_result} ->
        save_burst_reply(foundation_patient, members, chain_result, args)

      {:error, reason} ->
        raise "TelegramBurstReplyWorker: PhiWorker error: #{inspect(reason)}"
    end
  end

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
        raise "TelegramBurstReplyWorker: failed to save burst reply " <>
                "(reason=#{inspect(reason)})"
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
