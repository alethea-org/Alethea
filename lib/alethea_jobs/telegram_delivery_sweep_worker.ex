defmodule AletheaJobs.TelegramDeliverySweepWorker do
  @moduledoc """
  Resolves Telegram reply deliveries stuck in `sending` (issue #390).

  On the journaling lane `Alethea.Jobs.TelegramOutboundWorker` claims the
  reply row (`pending` -> `sending`) before it calls Telegram. If that
  execution dies after the claim — node loss, a raise, a failing outcome
  write — nothing else ever moves the row: the outbound job has
  `max_attempts: 1`, and any later execution refuses to send a claimed
  reply. This worker bounds that state. A claim older than
  `claim_timeout_seconds/0` is resolved to `ambiguous` (the request may
  have reached Telegram, so the reply is never resent) and surfaced
  through the outbound dead-letter path, exactly like an ambiguous
  outcome the outbound worker observes itself.

  ## Why a cron sweep and not a watchdog job per claim

  A watchdog scheduled with every claim would add an Oban job to every
  reply sent, would have to carry the reply body in its args (a second
  plaintext copy), and would still miss a claim whose watchdog insert was
  lost. The sweep costs nothing per send, keeps job args empty, reads the
  content from the encrypted row only when it has something to report,
  and catches every stuck row regardless of how it got there.

  ## Safety

    * The bound is ten minutes; cron runs every five, so a stuck reply is
      resolved within fifteen. The Telegram client's whole request is
      bounded by Req's defaults (30s connect + 15s receive), and the
      rate-limit wait happens before the claim, so a merely slow send has
      finished an order of magnitude earlier.
    * Resolution is `Alethea.Clinical.expire_telegram_delivery_claim/2`,
      one conditional UPDATE on state and age: it cannot overwrite `sent`
      and succeeds for one caller only, so overlapping or repeated sweeps
      surface a reply once. The state change and the dead-letter row
      commit together.
    * If a holder that overran the bound does hear back, its `sent` still
      wins over `ambiguous`.
    * Crisis replies are never claimed, so they never enter `sending` and
      this worker never touches them.

  `max_attempts: 1` — the next run picks up whatever a failed run left.
  """

  use Oban.Worker, queue: :telegram_outbound, max_attempts: 1

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Foundation.Accounts.Patient, as: FoundationPatient
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo

  @default_claim_timeout_seconds 600
  @unreadable_reply "[reply content unavailable]"

  @doc """
  How long a delivery claim may be held before it is considered
  abandoned. Overridable with
  `config :alethea, :telegram_delivery_claim_timeout_seconds`; must stay
  well above the Telegram client's request timeout.
  """
  @spec claim_timeout_seconds() :: pos_integer()
  def claim_timeout_seconds do
    Application.get_env(
      :alethea,
      :telegram_delivery_claim_timeout_seconds,
      @default_claim_timeout_seconds
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -claim_timeout_seconds(), :second)

    cutoff
    |> Clinical.stale_telegram_delivery_claims()
    |> Enum.each(&resolve(&1, cutoff))

    :ok
  end

  defp resolve(%Message{} = reply, cutoff) do
    {:ok, _} =
      Repo.transaction(fn ->
        case Clinical.expire_telegram_delivery_claim(reply.id, cutoff) do
          :ok -> surface(reply)
          :unchanged -> :ok
        end
      end)

    :ok
  end

  defp surface(%Message{} = reply) do
    case foundation_patient(reply.patient_id) do
      %FoundationPatient{telegram_chat_id_hash: chat_id_hash} = patient
      when is_binary(chat_id_hash) ->
        TelegramOutboundWorker.surface_ambiguous_delivery(%{
          chat_id_hash: chat_id_hash,
          patient_id: patient.id,
          body: reply_text(patient, reply),
          reason: {:ambiguous, :claim_expired},
          attempts: 1
        })

      _no_longer_bound ->
        # A dead-letter row needs the chat hash. The claim is still
        # resolved so the reply does not stay in `sending`.
        Logger.error(
          "TelegramDeliverySweepWorker: expired delivery claim resolved to ambiguous but " <>
            "not dead-lettered, patient has no Telegram chat (message_id=#{reply.id})"
        )

        :ok
    end
  end

  defp reply_text(patient, reply) do
    case Clinical.telegram_reply_text(patient, reply) do
      {:ok, text} when is_binary(text) and text != "" -> text
      _unreadable -> @unreadable_reply
    end
  end

  defp foundation_patient(legacy_patient_id) do
    Repo.one(
      from(p in FoundationPatient, where: p.legacy_patient_id == ^legacy_patient_id, limit: 1)
    )
  end
end
