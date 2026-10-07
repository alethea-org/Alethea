defmodule Alethea.Clinical do
  @moduledoc """
  Contexto clínico para guardar mensajes, leer el historial reciente y persistir resultados de IA.
  Gestiona también el ciclo de vida de sesiones y tendencias emocionales.

  **Boundary note**: journaling del paciente (mensajes, resúmenes,
  tendencias) vive acá — es distinto de `Alethea.ClinicalRecord`, que
  guarda las conductas objetivo y notas clínicas que autora el
  profesional. Son tablas separadas, sin writer compartido, sin path
  de escritura de IA hacia `target_behaviors` o `clinical_notes`.
  Cualquier archivo que importe ambos DEBE aliasear uno explícitamente,
  ej. `alias Alethea.Clinical, as: Journaling`, para evitar colisión visual.
  """

  import Ecto.Query, warn: false

  alias Alethea.Repo
  alias Alethea.Clinical.{Message, Outbox, Summary, Trend}
  alias Alethea.AI.Diagnosis
  alias Alethea.Clinical.EmotionAnalysis
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Encryption.PatientVault
  alias Alethea.Encryption.ProfessionalKek

  @spec save_message(
          Alethea.Accounts.Patient.t(),
          String.t(),
          binary() | nil,
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) ::
          {:ok, Message.t()} | {:error, term()}
  def save_message(
        patient,
        text,
        dek,
        direction,
        behavior_type,
        session_id \\ nil,
        telegram_message_id \\ nil
      ) do
    with {:ok, changeset} <-
           encrypted_message_changeset(
             patient,
             text,
             dek,
             direction,
             behavior_type,
             session_id,
             telegram_message_id
           ) do
      persist(changeset, direction, patient)
    end
  end

  defp encrypted_message_changeset(
         patient,
         text,
         dek,
         direction,
         behavior_type,
         session_id,
         telegram_message_id
       ) do
    with {:ok, dek} <- get_dek(patient, dek),
         {:ok, encrypted_content} <- PatientVault.encrypt(text, dek) do
      attrs = %{
        patient_id: patient.id,
        direction: direction,
        behavior_type: behavior_type,
        encrypted_content: encrypted_content,
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
        session_id: session_id
      }

      attrs =
        if telegram_message_id,
          do: Map.put(attrs, :telegram_message_id, telegram_message_id),
          else: attrs

      {:ok, Message.changeset(%Message{}, attrs)}
    end
  end

  # Inbound messages are the "voz del paciente" producer
  # (sdd/telegram-rag-ingestion-262, AD2): the Message row and the
  # `Clinical.Outbox` job commit atomically via `Ecto.Multi` so the
  # RAG indexer can never observe a persisted message with no
  # corresponding outbox event (or vice versa).
  #
  # Gated to `direction == "inbound"` ONLY (AD2 — key discovery): both
  # outbound call sites (`telegram_message_worker.ex`'s
  # `persist_and_enqueue_outbound/7` and `handle_crisis_path/9`)
  # already run INSIDE an enclosing `Repo.transaction`. Ecto nested
  # transactions take no savepoint — a failing inner
  # `Repo.transaction(multi)` would roll back the OUTER transaction,
  # after which the callers' own `Repo.rollback(reason)` in their
  # `else` branch could no longer run correctly. The outbound clause
  # below stays a byte-for-byte bare `Repo.insert/1` to keep that
  # path provably untouched.
  defp persist(changeset, "inbound", patient) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:message, changeset)
    |> Oban.insert(:outbox_event, fn %{message: message} ->
      Outbox.event("patient_message_received", message, patient.professional_id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        {:ok, message}

      {:error, :message, changeset, _changes} ->
        # AD3: remap onto the exact `{:error, %Ecto.Changeset{}}` shape
        # the public contract (and the worker's telegram_message_id
        # duplicate-detection branch, plus
        # `AletheaJobs.SafeReason.for_log/1`'s changeset pattern match)
        # already expects from the pre-Multi bare `Repo.insert/1` path.
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp persist(changeset, _direction, _patient) do
    Repo.insert(changeset)
  end

  @doc """
  Persists a `Message` for the Telegram channel (REQ-C3-worker-persists-message
  + REQ-C5-persist-inbound-message + REQ-C5-persist-outbound-reply).

  Unlike `save_message/7`, this variant takes the **foundation**
  `Alethea.Foundation.Accounts.Patient` (the row returned by
  `lookup_patient_by_chat_hash/1`) and the Telegram `message_id`. It
  resolves the legacy `Alethea.Accounts.Patient` via
  `Alethea.Foundation.Accounts.legacy_patient/1`, then delegates to
  `save_message/7` (passing `telegram_message_id` as the 7th arg) for
  the encryption + insert.

  The split between foundation and legacy Patient schemas is
  deliberate: the foundation row is the public identity surface
  (carries `telegram_chat_id_hash`, the tenant boundary); the legacy
  row backs the clinical pipeline (carries the DEK, the messages FK).
  This function is the single bridge.

  Returns `{:ok, %Message{}}` on success,
  `{:error, :not_linked}` if the foundation row has no
  `legacy_patient_id` set (the patient has not been onboarded to the
  clinical pipeline — should not happen in production for bound
  patients; surfaces the data integrity gap loudly),
  `{:error, :legacy_not_found}` if the referenced legacy row is gone,
  or `{:error, reason}` for downstream failures.

  ## Duplicate handling

  The partial unique index on `(patient_id, telegram_message_id)`
  rejects a second row for the same Telegram message in the same
  patient's conversation; this function surfaces the changeset error to
  the caller. Inbound callers that must survive a re-execution use
  `find_or_save_telegram_inbound/4` instead, which resumes the persisted
  row.
  """
  @spec save_telegram_message(
          Alethea.Foundation.Accounts.Patient.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          binary() | nil
        ) :: {:ok, Message.t()} | {:error, term()}
  def save_telegram_message(
        foundation_patient,
        text,
        direction,
        behavior_type,
        telegram_message_id,
        session_id \\ nil
      ) do
    case Alethea.Foundation.Accounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} ->
        save_message(
          legacy_patient,
          text,
          nil,
          direction,
          behavior_type,
          session_id,
          telegram_message_id
        )

      :not_linked ->
        {:error, :not_linked}

      {:error, :legacy_not_found} ->
        {:error, :legacy_not_found}
    end
  end

  @doc """
  Persists the inbound `Message` for a Telegram update, or returns the one
  already persisted for it (issue #390).

  The identity of an inbound is the Telegram `message_id` within the
  patient's conversation. A re-execution of the same job (Oban retry,
  concurrent execution, replay outside the Oban unique window) finds the
  existing row and resumes from it instead of failing on the unique
  index. The row is created together with its patient-voice outbox event
  exactly once (see `persist/3`).

  If two executions race on the insert, the loser's insert is rejected by
  the unique index and it returns the winner's row.

  Returns `{:ok, %Message{}}`, or the same errors as
  `save_telegram_message/6`.
  """
  @spec find_or_save_telegram_inbound(
          Alethea.Foundation.Accounts.Patient.t(),
          String.t(),
          String.t(),
          binary() | nil
        ) :: {:ok, Message.t()} | {:error, term()}
  def find_or_save_telegram_inbound(foundation_patient, text, telegram_message_id, session_id) do
    case Alethea.Foundation.Accounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} ->
        case get_telegram_inbound(legacy_patient.id, telegram_message_id) do
          %Message{} = existing ->
            {:ok, existing}

          nil ->
            legacy_patient
            |> save_message(
              text,
              nil,
              "inbound",
              "spontaneous",
              session_id,
              telegram_message_id
            )
            |> resume_on_duplicate_inbound(legacy_patient.id, telegram_message_id)
        end

      :not_linked ->
        {:error, :not_linked}

      {:error, :legacy_not_found} ->
        {:error, :legacy_not_found}
    end
  end

  defp get_telegram_inbound(patient_id, telegram_message_id) do
    Repo.one(
      from(m in Message,
        where:
          m.patient_id == ^patient_id and m.direction == "inbound" and
            m.telegram_message_id == ^telegram_message_id
      )
    )
  end

  defp resume_on_duplicate_inbound(
         {:error, %Ecto.Changeset{} = changeset} = error,
         patient_id,
         telegram_message_id
       ) do
    with true <- unique_violation?(changeset, :telegram_message_id),
         %Message{} = winner <- get_telegram_inbound(patient_id, telegram_message_id) do
      {:ok, winner}
    else
      _ -> error
    end
  end

  defp resume_on_duplicate_inbound(result, _patient_id, _telegram_message_id), do: result

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  @doc """
  Persists the outbound reply to one inbound Telegram message (issue #390).

  The row records its provenance in `reply_to_message_id`, under a unique
  index: an inbound has at most one reply. The content is encrypted with
  the patient's DEK exactly like any other message. Its delivery starts
  as `"pending"` (see `claim_telegram_delivery/1`).

  Returns `{:error, :reply_already_exists}` when another execution already
  persisted the reply for this inbound; the caller reuses that reply
  (`get_telegram_reply/1`) instead of persisting or delivering a second
  one. Like every outbound save it is a bare insert, safe to call inside
  the caller's `Repo.transaction` (see `persist/3`).
  """
  @spec save_telegram_reply(
          Alethea.Foundation.Accounts.Patient.t(),
          String.t(),
          String.t(),
          binary(),
          binary() | nil
        ) :: {:ok, Message.t()} | {:error, :reply_already_exists} | {:error, term()}
  def save_telegram_reply(foundation_patient, text, behavior_type, inbound_message_id, session_id) do
    with {:ok, legacy_patient} <- linked_legacy_patient(foundation_patient),
         {:ok, changeset} <-
           encrypted_message_changeset(
             legacy_patient,
             text,
             nil,
             "outbound",
             behavior_type,
             session_id,
             nil
           ) do
      changeset
      |> Ecto.Changeset.put_change(:reply_to_message_id, inbound_message_id)
      |> Ecto.Changeset.put_change(:delivery_state, "pending")
      |> Repo.insert()
      |> case do
        {:ok, reply} ->
          {:ok, reply}

        {:error, %Ecto.Changeset{} = failed} = error ->
          if unique_violation?(failed, :reply_to_message_id),
            do: {:error, :reply_already_exists},
            else: error
      end
    end
  end

  @doc """
  Returns the reply persisted for an inbound Telegram message, or `nil`.
  """
  @spec get_telegram_reply(binary()) :: Message.t() | nil
  def get_telegram_reply(inbound_message_id) do
    Repo.get_by(Message, reply_to_message_id: inbound_message_id)
  end

  @doc """
  Returns every uncovered inbound Telegram message for
  `foundation_patient`, decrypted, ordered by `telegram_message_id` as
  an integer — not text, not `inserted_at` (#391, R2).

  A member is a row where `replied_by_message_id` IS NULL, or where it
  points at a reply that is still `"pending"`: a new burst also
  absorbs the patient's still-undelivered ordinary reply, so that
  reply's members join the new burst instead of being dispatched stale
  (design AD5, R11).

  Rows backfilled with the self-reference marker
  (`replied_by_message_id == id`, design AD2, the migration that added
  this column) are legacy, outside the burst model: a self-reference
  can never satisfy the `IS NULL` check or appear in the pending-reply
  subquery, so they are excluded the same way a genuinely covered row
  is (R10).
  """
  @spec list_burst_members(Alethea.Foundation.Accounts.Patient.t()) ::
          {:ok, [{Message.t(), String.t()}]} | {:error, term()}
  def list_burst_members(foundation_patient) do
    with {:ok, legacy_patient} <- linked_legacy_patient(foundation_patient),
         {:ok, dek} <- patient_dek(legacy_patient) do
      legacy_patient.id
      |> burst_members_query()
      |> Repo.all()
      |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
        case decrypt_message_content(message, dek) do
          {:ok, content} -> {:cont, {:ok, [{message, content} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp burst_members_query(patient_id) do
    pending_reply_ids =
      from(r in Message,
        where:
          r.patient_id == ^patient_id and r.direction == "outbound" and
            r.behavior_type == "elicited" and r.delivery_state == "pending",
        select: r.id
      )

    from(m in Message,
      where:
        m.patient_id == ^patient_id and m.direction == "inbound" and
          not is_nil(m.telegram_message_id) and
          (is_nil(m.replied_by_message_id) or
             m.replied_by_message_id in subquery(pending_reply_ids)),
      order_by: fragment("?::bigint", m.telegram_message_id)
    )
  end

  @doc """
  Locks the patient's conversation for the rest of the caller's
  transaction (design AD6): `SELECT … FROM patients WHERE id = $1 FOR
  UPDATE`. Serializes the burst save transaction and the crisis
  transaction against each other, so a coverage write can never
  observe a stale view of the other's progress (#391).

  Lock order across the feature is always the patient, then outbound
  rows (the dispatch claim), then inbound rows (burst coverage) — the
  same order the dispatch transaction takes — so this call can never
  deadlock against it.

  Must be called inside a `Repo.transaction/1`; the lock releases at
  commit or rollback. Raises `Ecto.NoResultsError` if the patient does
  not exist (a caller-side bug, not a runtime race).
  """
  @spec lock_patient_conversation!(binary()) :: :ok
  def lock_patient_conversation!(patient_id) do
    Repo.one!(
      from(p in Alethea.Accounts.Patient,
        where: p.id == ^patient_id,
        select: p.id,
        lock: "FOR UPDATE"
      )
    )

    :ok
  end

  @doc """
  Marks `reply_ids` superseded, from `"pending"` only (design AD5): a
  burst also absorbs the patient's still-undelivered ordinary reply.
  Returns the number of rows actually moved — the caller compares it
  against `length(reply_ids)` to detect a lost race (the dispatch
  claim moved one to `"sending"` first) and roll back (#391, R11).
  """
  @spec supersede_absorbed([binary()]) :: non_neg_integer()
  def supersede_absorbed([]), do: 0

  def supersede_absorbed(reply_ids) when is_list(reply_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(m in Message, where: m.id in ^reply_ids and m.delivery_state == "pending")
      |> Repo.update_all(set: [delivery_state: "superseded", updated_at: now])

    count
  end

  @doc """
  Claims coverage of `member_ids` for `reply_id` (design core SQL):
  only rows that are still uncovered (`replied_by_message_id IS NULL`)
  or covered by one of `absorbed_reply_ids` (a reply this same save is
  superseding via `supersede_absorbed/1`, design AD5) are moved. A row
  already covered by a different, still-live reply is left untouched —
  as is a self-covered legacy row (design AD2), which can never match
  either predicate (its `replied_by_message_id` equals its own `id`,
  never `NULL` and never a reply id). Returns the number of rows
  moved; the caller compares it against `length(member_ids)` to detect
  a lost race (#391, R2, R6, R11).
  """
  @spec cover_members([binary()], binary(), [binary()]) :: non_neg_integer()
  def cover_members(member_ids, reply_id, absorbed_reply_ids \\ [])

  def cover_members([], _reply_id, _absorbed_reply_ids), do: 0

  def cover_members(member_ids, reply_id, absorbed_reply_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(m in Message,
        where:
          m.id in ^member_ids and
            (is_nil(m.replied_by_message_id) or
               m.replied_by_message_id in ^absorbed_reply_ids)
      )
      |> Repo.update_all(set: [replied_by_message_id: reply_id, updated_at: now])

    count
  end

  @doc """
  True if `patient_id` has any Telegram inbound row with no coverage
  (`replied_by_message_id IS NULL`) — design's invariant I check.
  Used at save time to detect a newer inbound that arrived during
  generation (R3), and after a crisis release to decide whether to
  re-arm (AD4, crisis step 6). A self-covered legacy row (design AD2)
  is never uncovered, so pre-#391 backlog never reports `true` (#391).
  """
  @spec uncovered_inbound?(binary()) :: boolean()
  def uncovered_inbound?(patient_id) do
    Repo.exists?(
      from(m in Message,
        where:
          m.patient_id == ^patient_id and m.direction == "inbound" and
            not is_nil(m.telegram_message_id) and is_nil(m.replied_by_message_id)
      )
    )
  end

  @doc """
  Ids of the patient's still-`"pending"` ordinary (`"elicited"`)
  replies (design's crisis step 2; the same subquery
  `list_burst_members/1` uses for absorption, design AD5, #391).
  """
  @spec pending_reply_ids(binary()) :: [binary()]
  def pending_reply_ids(patient_id) do
    Repo.all(
      from(m in Message,
        where:
          m.patient_id == ^patient_id and m.direction == "outbound" and
            m.behavior_type == "elicited" and m.delivery_state == "pending",
        select: m.id
      )
    )
  end

  @doc """
  Ids of the inbound Telegram messages a crisis reply must cover
  (design's crisis step 4): every row up to and including `crisis_tg`
  (compared as an integer, not text) that is uncovered, or covered by
  one of `pending_ids` — a reply this same crisis is about to
  supersede via `supersede_absorbed/1` (design AD5 applied to the
  crisis path, #391, R5).
  """
  @spec crisis_cover_candidates(binary(), String.t(), [binary()]) :: [binary()]
  def crisis_cover_candidates(patient_id, crisis_tg, pending_ids) do
    crisis_tg_int = String.to_integer(crisis_tg)

    Repo.all(
      from(m in Message,
        where:
          m.patient_id == ^patient_id and m.direction == "inbound" and
            not is_nil(m.telegram_message_id) and
            fragment("?::bigint", m.telegram_message_id) <= ^crisis_tg_int and
            (is_nil(m.replied_by_message_id) or m.replied_by_message_id in ^pending_ids),
        select: m.id
      )
    )
  end

  @doc """
  Releases coverage from `reply_ids` (design's crisis step 5): a row
  still pointing at one of these is a member of the just-superseded
  reply that `crisis_cover_candidates/3` did NOT also hand to the
  crisis reply, because it postdates `crisis_tg` (processed out of
  order — #391, R5 "after crisis"). Setting it back to `NULL` lets the
  next burst arm pick it up. Returns the number of rows released; the
  caller re-arms only when this is greater than zero (design's crisis
  step 6, AD4).
  """
  @spec release_coverage([binary()]) :: non_neg_integer()
  def release_coverage([]), do: 0

  def release_coverage(reply_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(m in Message, where: m.replied_by_message_id in ^reply_ids)
      |> Repo.update_all(set: [replied_by_message_id: nil, updated_at: now])

    count
  end

  @doc """
  Decrypts a persisted reply so a resumed execution can deliver the
  content the clinical record already holds instead of generating a new
  one. The plaintext is returned to the caller only; it is never logged.
  """
  @spec telegram_reply_text(Alethea.Foundation.Accounts.Patient.t(), Message.t()) ::
          {:ok, String.t()} | {:error, term()}
  def telegram_reply_text(foundation_patient, %Message{} = reply) do
    with {:ok, legacy_patient} <- linked_legacy_patient(foundation_patient),
         {:ok, dek} <- patient_dek(legacy_patient) do
      decrypt_message_content(reply, dek)
    end
  end

  @typedoc """
  Delivery outcome of an outbound Telegram reply:

    * `"pending"` — persisted, no send in progress.
    * `"sending"` — one execution of the delivery job holds the claim.
    * `"sent"` — Telegram acknowledged the message.
    * `"ambiguous"` — the request may have reached Telegram and nobody
      knows whether it was delivered. Never resent.
    * `"failed"` — the retry budget ran out before any send.
    * `"superseded"` — the reply's coverage was reclaimed by a later
      burst or crisis reply before it was dispatched (#391). Never
      sent; excluded from `list_conversation_turns/3`.

  `nil` means the row is not a tracked reply.
  """
  @type telegram_delivery_state :: String.t() | nil

  @doc """
  Claims the delivery of a persisted reply for one execution of the
  delivery job (`"pending"` -> `"sending"`), atomically.

  Returns `:claimed` to exactly one caller. Every other caller gets
  `{:not_claimed, state}` with the state it lost to, and must not send:
  the reply is already sent, in flight, or in an outcome that forbids a
  resend.
  """
  @spec claim_telegram_delivery(binary()) ::
          :claimed | {:not_claimed, telegram_delivery_state()}
  def claim_telegram_delivery(message_id) do
    case move_telegram_delivery(message_id, ["pending"], delivery_state: "sending") do
      :ok -> :claimed
      :unchanged -> {:not_claimed, telegram_delivery_state(message_id)}
    end
  end

  @doc """
  Returns the delivery state of a message, `nil` when it is untracked or
  does not exist.
  """
  @spec telegram_delivery_state(binary()) :: telegram_delivery_state()
  def telegram_delivery_state(message_id) do
    Repo.one(from(m in Message, where: m.id == ^message_id, select: m.delivery_state))
  end

  @doc """
  Records the outcome of a delivery attempt. Each outcome only applies
  from the states it may legitimately follow, so a late or duplicate
  report can never undo a stronger one:

    * `{:sent, telegram_message_id}` — acknowledged. Wins over
      `"ambiguous"`: the execution holding the claim learned the truth.
    * `:not_sent` — the holder knows its request never reached Telegram;
      the reply returns to `"pending"` for a later attempt.
    * `:ambiguous` — only from `"sending"`; never downgrades `"sent"`.
    * `:failed` — retry budget exhausted without a send.

  Returns `:ok` when the row moved and `:unchanged` otherwise (including
  untracked rows, which stay untouched).
  """
  @spec record_telegram_delivery(
          binary(),
          {:sent, integer() | String.t() | nil} | :not_sent | :ambiguous | :failed
        ) :: :ok | :unchanged
  def record_telegram_delivery(message_id, {:sent, telegram_message_id}) do
    move_telegram_delivery(message_id, ["pending", "sending", "ambiguous"],
      delivery_state: "sent",
      delivered_telegram_message_id: telegram_message_id && to_string(telegram_message_id)
    )
  end

  def record_telegram_delivery(message_id, :not_sent) do
    move_telegram_delivery(message_id, ["sending", "ambiguous"], delivery_state: "pending")
  end

  def record_telegram_delivery(message_id, :ambiguous) do
    move_telegram_delivery(message_id, ["sending"], delivery_state: "ambiguous")
  end

  def record_telegram_delivery(message_id, :failed) do
    move_telegram_delivery(message_id, ["pending", "sending", "ambiguous"],
      delivery_state: "failed"
    )
  end

  @doc """
  Replies whose delivery claim has been held since before `cutoff`
  without a recorded outcome. The execution that claimed them is either
  dead or has overrun every plausible request time.
  """
  @spec stale_telegram_delivery_claims(DateTime.t()) :: [Message.t()]
  def stale_telegram_delivery_claims(%DateTime{} = cutoff) do
    Repo.all(
      from(m in Message,
        where: m.delivery_state == "sending" and m.updated_at < ^cutoff,
        order_by: m.updated_at
      )
    )
  end

  @doc """
  Resolves one expired delivery claim to `"ambiguous"`: the request may
  have reached Telegram, so the reply is never resent.

  The age and state checks are part of the UPDATE itself, so it cannot
  overwrite `"sent"`, cannot touch a claim that was renewed since it was
  listed, and returns `:ok` to exactly one caller — a second run gets
  `:unchanged`.
  """
  @spec expire_telegram_delivery_claim(binary(), DateTime.t()) :: :ok | :unchanged
  def expire_telegram_delivery_claim(message_id, %DateTime{} = cutoff) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(m in Message,
        where: m.id == ^message_id and m.delivery_state == "sending" and m.updated_at < ^cutoff
      )
      |> Repo.update_all(set: [delivery_state: "ambiguous", updated_at: now])

    if count == 1, do: :ok, else: :unchanged
  end

  # Single conditional UPDATE: the state check and the write are one
  # statement, so concurrent executions cannot both observe the same
  # source state.
  defp move_telegram_delivery(message_id, from_states, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(m in Message, where: m.id == ^message_id and m.delivery_state in ^from_states)
      |> Repo.update_all(set: Keyword.put(changes, :updated_at, now))

    if count == 1, do: :ok, else: :unchanged
  end

  defp linked_legacy_patient(foundation_patient) do
    case Alethea.Foundation.Accounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} -> {:ok, legacy_patient}
      :not_linked -> {:error, :not_linked}
      {:error, :legacy_not_found} -> {:error, :legacy_not_found}
    end
  end

  @spec list_recent_messages(binary(), non_neg_integer()) :: [Message.t()]
  def list_recent_messages(patient_id, limit) when is_integer(limit) and limit > 0 do
    Message
    |> where(patient_id: ^patient_id)
    |> order_by(desc: :timestamp)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec get_message(binary()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @spec get_message_emotions(binary()) :: {:ok, EmotionAnalysis.t()} | {:error, :not_found}
  def get_message_emotions(message_id) do
    case Repo.get_by(EmotionAnalysis, message_id: message_id) do
      nil -> {:error, :not_found}
      emotion -> {:ok, emotion}
    end
  end

  def list_session_messages(session_id) do
    Repo.all(
      from(m in Message,
        where: m.session_id == ^session_id and m.direction == "inbound"
      )
    )
  end

  @spec build_patient_context(Alethea.Accounts.Patient.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def build_patient_context(patient, limit) do
    with {:ok, dek} <- patient_dek(patient) do
      patient.id
      |> list_recent_messages(limit)
      |> Enum.reverse()
      |> Enum.map(&decrypt_message_content(&1, dek))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, decrypted}, {:ok, acc} -> {:cont, {:ok, [decrypted | acc]}}
        {:error, reason}, _ -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, decrypted_messages} ->
          {:ok, decrypted_messages |> Enum.reverse() |> Enum.join("\n")}

        error ->
          error
      end
    end
  end

  @typedoc """
  One prior journaling message with the speaker made explicit:
  `:patient` for inbound messages, `:alethea` for outbound ones.
  """
  @type conversation_turn :: %{role: :patient | :alethea, content: String.t()}

  @doc """
  Returns up to `limit` journaling turns that precede `current` (the
  message being answered), oldest first, each tagged with its speaker.

  `current` itself is never part of the result — the caller supplies it
  once, as the current turn — and neither is anything that sorts after
  it, so regenerating a reply for the same message reads the same
  snapshot.

  ## Ordering

  `messages.timestamp` is second-truncated, so it cannot order two rows
  written within the same second. Ties are broken by `direction` (the
  patient's message before Alethea's reply, the only order a turn-based
  exchange produces inside one second) and then by `id`, which makes the
  result deterministic without a schema change. Two messages of the same
  direction inside one second keep a stable but arbitrary relative order.

  Content is returned decrypted and unsanitized; callers that hand it to
  a model must pass it through `Alethea.AI.Sanitizer` first.
  """
  @spec list_conversation_turns(Alethea.Accounts.Patient.t(), Message.t(), pos_integer()) ::
          {:ok, [conversation_turn()]} | {:error, term()}
  def list_conversation_turns(patient, %Message{} = current, limit)
      when is_integer(limit) and limit > 0 do
    with {:ok, dek} <- patient_dek(patient) do
      patient.id
      |> turns_before(current, limit)
      |> Enum.reduce_while({:ok, []}, fn message, {:ok, turns} ->
        case decrypt_message_content(message, dek) do
          {:ok, content} ->
            {:cont, {:ok, [%{role: turn_role(message), content: content} | turns]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Newest first, so `limit` keeps the most recent turns; the reduce in
  # `list_conversation_turns/3` prepends and thereby restores
  # chronological order.
  defp turns_before(patient_id, %Message{} = current, limit) do
    Message
    |> where([m], m.patient_id == ^patient_id)
    |> where([m], is_nil(m.delivery_state) or m.delivery_state != "superseded")
    |> where(
      [m],
      m.timestamp < ^current.timestamp or
        (m.timestamp == ^current.timestamp and m.direction < ^current.direction) or
        (m.timestamp == ^current.timestamp and m.direction == ^current.direction and
           m.id < ^current.id)
    )
    |> order_by([m], desc: m.timestamp, desc: m.direction, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp turn_role(%Message{direction: "inbound"}), do: :patient
  defp turn_role(%Message{direction: "outbound"}), do: :alethea

  @spec save_ai_diagnosis(binary(), map()) :: {:ok, Diagnosis.t()} | {:error, term()}
  def save_ai_diagnosis(message_id, chain_result) do
    attrs = %{
      message_id: message_id,
      model_version:
        Map.get(chain_result, :model_version) || Map.get(chain_result, "model_version"),
      extracted_emotions:
        Map.get(chain_result, :extracted_emotions) || Map.get(chain_result, "extracted_emotions") ||
          %{},
      ai_response: Map.get(chain_result, :response) || Map.get(chain_result, "response")
    }

    %Diagnosis{}
    |> Diagnosis.changeset(attrs)
    |> Repo.insert()
  end

  def save_trends(patient, emotion_scores, _session) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(emotion_scores, fn %{label: label, score: score} ->
      last_trend =
        Repo.one(
          from(t in Trend,
            where: t.patient_id == ^patient.id and t.indicator_name == ^label,
            order_by: [desc: t.recorded_at],
            limit: 1
          )
        )

      delta = if last_trend, do: score - last_trend.score, else: 0.0

      %Trend{}
      |> Trend.changeset(%{
        indicator_name: label,
        score: score,
        delta: delta,
        recorded_at: now,
        patient_id: patient.id
      })
      |> Repo.insert!()
    end)

    :ok
  end

  @spec save_trends_from_analysis(EmotionAnalysis.t(), binary()) :: :ok
  def save_trends_from_analysis(%EmotionAnalysis{} = analysis, patient_id) do
    emotion_scores = [
      %{label: "joy", score: analysis.joy_score || 0.0},
      %{label: "sadness", score: analysis.sadness_score || 0.0},
      %{label: "anger", score: analysis.anger_score || 0.0},
      %{label: "fear", score: analysis.fear_score || 0.0},
      %{label: "neutral", score: analysis.neutral_score || 0.0}
    ]

    # save_trends espera un patient struct,，所以我们用虚拟结构
    fake_patient = %Alethea.Accounts.Patient{id: patient_id}
    save_trends(fake_patient, emotion_scores, nil)
  end

  def save_summary(attrs) do
    %Summary{}
    |> Summary.changeset(attrs)
    |> Repo.insert()
  end

  def list_session_summaries(patient_id, since) do
    Repo.all(
      from(s in Summary,
        where:
          s.patient_id == ^patient_id and
            s.type == "session" and
            s.period_start >= ^since
      )
    )
  end

  @doc """
  Devuelve el reporte semanal más reciente del paciente, o `nil` si no hay ninguno.

  No filtra por fecha: un reporte semanal cubre la semana *anterior*, así que su
  `period_start` casi siempre queda fuera de una ventana de 7 días.
  """
  @spec latest_weekly_summary(binary()) :: Summary.t() | nil
  def latest_weekly_summary(patient_id) do
    Repo.one(
      from(s in Summary,
        where: s.patient_id == ^patient_id and s.type == "weekly",
        order_by: [desc: s.period_end, desc: s.inserted_at],
        limit: 1
      )
    )
  end

  @spec list_daily_emotion_scores(binary(), DateTime.t()) :: [map()]
  def list_daily_emotion_scores(patient_id, since) do
    Repo.all(
      from ea in EmotionAnalysis,
        join: m in Message,
        on: ea.message_id == m.id,
        where:
          m.patient_id == ^patient_id and
            m.timestamp >= ^since and
            m.direction == "inbound",
        group_by: fragment("?::date", m.timestamp),
        order_by: [asc: fragment("?::date", m.timestamp)],
        select: %{
          date: fragment("?::date", m.timestamp),
          joy: avg(ea.joy_score),
          sadness: avg(ea.sadness_score),
          anger: avg(ea.anger_score),
          fear: avg(ea.fear_score),
          neutral: avg(ea.neutral_score)
        }
    )
  end

  def aggregate_trends(patient_id, since) do
    Repo.all(
      from(t in Trend,
        where: t.patient_id == ^patient_id and t.recorded_at >= ^since,
        group_by: t.indicator_name,
        select: {t.indicator_name, avg(t.score)}
      )
    )
    |> Enum.map(fn {name, avg_score} -> %{label: name, score: avg_score} end)
  end

  def decrypt_message_content(%Message{} = message, dek) do
    PatientVault.decrypt(message.encrypted_content, dek)
  end

  def get_dek(patient, dek \\ nil)
  def get_dek(_patient, dek) when is_binary(dek) and byte_size(dek) == 32, do: {:ok, dek}
  def get_dek(patient, _), do: patient_dek(patient)

  def patient_dek(patient) do
    patient = Repo.preload(patient, :professional)

    with %Alethea.Accounts.Professional{} = professional <- patient.professional,
         {:ok, kek} <- ProfessionalKek.load_kek(professional),
         %EncryptionKey{} = key <- Repo.get(EncryptionKey, patient.encryption_key_id),
         {:ok, dek} <- PatientVault.decrypt(key.encrypted_key, kek) do
      # Registrar acceso a datos sensibles (Auditoría)
      Alethea.Accounts.log_action(%{
        professional_id: professional.id,
        action: "PII_DECRYPT",
        resource_type: "Patient",
        resource_id: patient.id,
        details: %{reason: "clinical_context_loading"}
      })

      {:ok, dek}
    else
      nil -> {:error, :missing_encryption_key}
      {:error, reason} -> {:error, reason}
    end
  end
end
