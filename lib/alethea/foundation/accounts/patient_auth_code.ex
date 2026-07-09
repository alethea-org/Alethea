defmodule Alethea.Foundation.Accounts.PatientAuthCode do
  @moduledoc """
  Ephemeral onboarding code (C-4, PR #4). Persists both the deep-link
  token (`kind: "deep_link"`, minted by `Alethea.Telegram.DeepLinkToken.mint/0`)
  and the six-digit web fallback code (`kind: "six_digit"`) that bind a
  Telegram chat to a `Alethea.Foundation.Accounts.Patient` row.

  ## Lifecycle

    1. `create_patient_auth_code/2` — mints a fresh code with a 10-minute
       TTL, `used_at: nil`, `attempt_count: 0`.
    2. `verify_patient_auth_code/3` — checks eligibility (not expired, not
       used, not rate-limited) WITHOUT mutating the patient. Tracks the
       rate-limit audit trail on the row itself.
    3. `consume_patient_auth_code/3` — atomically binds the patient's
       `telegram_chat_id_hash` AND marks the code used, in a single
       `Ecto.Multi` transaction. If the chat is already bound to a
       DIFFERENT patient, the whole transaction rolls back — the code
       stays unused and retryable (REQ-C4-reject-chat-bound-to-other-patient).

  ## Rate-limit algorithm (REQ-C4-reject-rate-limited)

  The row has exactly one `attempt_count` and one `last_attempt_ip` —
  there is no per-attempt history table. The rolling 1-hour window is
  reconstructed from the row's own `updated_at` (bumped by Ecto on every
  `verify_patient_auth_code/3` mutation):

    - If this call's `ip` matches `last_attempt_ip` AND the row was last
      touched < 1 hour ago: the attempt is part of the SAME ongoing
      window → `attempt_count` is incremented.
    - Otherwise (a different IP, OR the last touch was ≥ 1 hour ago):
      the window has rolled off (or a different actor is calling) →
      `attempt_count` resets to 1 and `last_attempt_ip` is overwritten.

  A call is rejected once the (post-increment) count reaches 5. The
  counter keeps growing on subsequent blocked calls so the audit trail
  reflects the true attempt count, not a value clamped at the cap.

  This design keeps the rate limit scoped to a SINGLE auth-code row
  (the natural unit — an attacker guessing one specific token) using
  only the columns the migration already provides, with no separate
  ETS table or ledger.

  ### Guessing a code that matches no row

  A code that matches NO row (a wrong six-digit guess, or a garbled
  token) has no row of its own to carry `attempt_count` /
  `last_attempt_ip` — left untracked, this would let an attacker
  enumerate the six-digit keyspace from one IP with zero throttling.
  `verify_patient_auth_code/3` closes this gap by tracking the attempt
  against a stand-in row of the SAME `kind`: it prefers a row this IP
  has already been tracked against (`kind` + `last_attempt_ip` — the
  same columns the migration's `(last_attempt_ip, inserted_at)` index
  targets), so repeated wrong guesses from one IP accumulate on the
  SAME row; failing that (a brand-new attacking IP), it falls back to
  the most recently minted still-live (`used_at: nil`) row of that
  `kind` to bootstrap tracking. The SAME reactive threshold as above
  (5 attempts / rolling hour) then applies.

  Accepted limitation: this can bump `attempt_count` /
  `last_attempt_ip` on a row that belongs to an unrelated, legitimate
  patient (the stand-in is borrowed, not owned by the attacker) — a
  deliberate, documented tradeoff to avoid a new table, matching this
  module's existing risk-acceptance style (see "Six-digit collision
  probability" below). If NO row of the given `kind` exists at all,
  the attempt is not trackable — but there is also nothing to attack.

  ## Six-digit collision probability (accepted risk)

  Per the `(patient_id, code, kind)` unique index (not a GLOBAL unique
  on `(code, kind)`), two different patients could theoretically be
  minted the identical 6-digit code within the same 10-minute window
  (1-in-1,000,000 chance per pair). `verify_patient_auth_code/3` and
  `consume_patient_auth_code/3` resolve this by taking the
  most-recently-inserted matching row SCOPED BY `kind` (`where: code
  == ^code and kind == ^kind`, `order_by: [desc: :inserted_at], limit:
  1`) rather than raising on an ambiguous match. Both functions share
  the exact same resolution query so they always agree on which row a
  given `(code, kind)` pair refers to — a `code` collision across two
  DIFFERENT `kind`s (e.g. a deep-link token that happens to equal
  another patient's six-digit code as a raw string) can never be
  ambiguous, since `kind` is part of the match. This mirrors the
  design's chosen index scope; a stricter global-unique constraint on
  six-digit codes is a follow-up if the collision risk becomes material
  at scale.

  ## `consume_patient_auth_code/3` — why the extra `kind` argument

  `tasks.md` names this function `consume_patient_auth_code/1`. The
  bind step needs the caller-supplied `chat_id_hash` to write onto the
  patient row, and REQ-C4-reject-chat-bound-to-other-patient requires
  the bind + consume to be a SINGLE atomic operation (so a unique
  constraint violation on the bind rolls back the `used_at` write too).
  A one-argument `consume_patient_auth_code(code)` that only marks
  `used_at` would force the caller to bind FIRST and consume SECOND as
  two separate writes — a window where a crash between the two leaves
  the patient bound but the code still marked unused (double-bind risk
  on retry). The atomic `Ecto.Multi` requires `chat_id_hash` as an
  argument, hence arity > 1.

  `kind` is required (as `opts[:kind]`, mirroring
  `verify_patient_auth_code/3`'s own signature) because a bare
  `code` alone is not guaranteed to resolve to a single row — see
  "Six-digit collision probability" above. Fetching by `code` alone
  (no `kind` filter) can raise `Ecto.MultipleResultsError` when two
  rows share the same `code` value across different `kind`s or
  patients; scoping by `(code, kind)` — the same scope
  `fetch_by_code_and_kind/2` already uses — keeps the two functions in
  agreement and removes the crash risk entirely.

  ## Row locking

  The auth-code row is fetched with `lock: "FOR UPDATE"` inside the
  `Ecto.Multi` transaction, so two concurrent `consume_patient_auth_code/3`
  calls for the SAME row serialize: the second call blocks until the
  first transaction commits (or rolls back), then re-reads the row —
  by then `used_at` is set, so it correctly returns `{:error,
  :already_used}` instead of racing the first call to a double-bind.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Alethea.Foundation.Accounts.Patient
  alias Alethea.Repo

  @kinds ~w(deep_link six_digit)

  @ttl_seconds 600
  @rate_limit_max_attempts 5
  @rate_limit_window_seconds 3600

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_patient_auth_codes" do
    belongs_to :patient, Patient

    field :code, :string
    field :kind, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :attempt_count, :integer, default: 0
    field :last_attempt_ip, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(auth_code, attrs) do
    auth_code
    |> cast(attrs, [
      :patient_id,
      :code,
      :kind,
      :expires_at,
      :used_at,
      :attempt_count,
      :last_attempt_ip
    ])
    |> validate_required([:patient_id, :code, :kind, :expires_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:patient_id, :code, :kind],
      name: :foundation_patient_auth_codes_patient_code_kind_unique
    )
  end

  @doc """
  Mints a fresh auth code for `patient_id`. `opts` must include
  `kind: "deep_link" | "six_digit"`.

  Per `REQ-C4-mint-deep-link-token`, the row is created with
  `expires_at = now + 10 min`, `used_at: nil`, `attempt_count: 0`,
  `last_attempt_ip: nil`.
  """
  @spec create_patient_auth_code(binary(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create_patient_auth_code(patient_id, opts) do
    kind = Keyword.fetch!(opts, :kind)
    code = generate_code(kind)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@ttl_seconds, :second)
      |> DateTime.truncate(:second)

    %__MODULE__{}
    |> changeset(%{
      patient_id: patient_id,
      code: code,
      kind: kind,
      expires_at: expires_at,
      used_at: nil,
      attempt_count: 0,
      last_attempt_ip: nil
    })
    |> Repo.insert()
  end

  @doc """
  Checks whether `code` (scoped by `kind:`) is eligible to be consumed,
  WITHOUT mutating the patient row.

  Returns:
    - `:ok` — valid, unexpired, unused, not rate-limited.
    - `:expired` — TTL passed (or the code does not exist — see the
      moduledoc "unknown code" note below). No mutation.
    - `:already_used` — `used_at` already set. No mutation.
    - `:rate_limited` — 5th+ attempt from the same IP within the
      rolling 1-hour window. `attempt_count` / `last_attempt_ip` ARE
      updated (the audit trail keeps recording attempts even once
      blocked).

  ## Unknown code

  A `code` that matches no row is treated identically to `:expired`.
  There is no user-facing distinction between "this link never
  existed" and "this link is too old" — both messages tell the patient
  to ask their therapist for a new one, and conflating the two avoids
  giving an attacker an oracle to distinguish a wrong guess from an
  expired-but-once-valid code.
  """
  @spec verify_patient_auth_code(String.t(), String.t() | nil, keyword()) ::
          :ok | :expired | :already_used | :rate_limited
  def verify_patient_auth_code(code, ip, opts) do
    kind = Keyword.fetch!(opts, :kind)

    case fetch_by_code_and_kind(code, kind) do
      nil ->
        check_unmatched_rate_limit(ip, kind)

      %__MODULE__{used_at: %DateTime{}} ->
        :already_used

      %__MODULE__{} = auth_code ->
        if expired?(auth_code) do
          :expired
        else
          check_rate_limit(auth_code, ip)
        end
    end
  end

  @doc """
  Atomically binds `chat_id_hash` onto the auth code's patient AND
  marks the code used, in a single transaction.

  Returns:
    - `{:ok, %Patient{}}` — the (now-bound) patient row.
    - `{:error, :already_used}` — the code was already consumed.
    - `{:error, :chat_bound_to_other_patient}` — the `chat_id_hash` is
      already bound to a DIFFERENT patient (the DB's partial unique
      index on `foundation_patients.telegram_chat_id_hash` rejected the
      bind). The code is NOT marked used — the transaction rolled back
      — so it stays retryable once the collision is resolved
      (REQ-C4-reject-chat-bound-to-other-patient).

  A same-patient rebind (the auth code's own patient updating its
  `telegram_chat_id_hash` to a new value) never hits the unique index
  and succeeds normally.
  """
  @spec consume_patient_auth_code(String.t(), String.t(), keyword()) ::
          {:ok, Patient.t()} | {:error, :already_used | :chat_bound_to_other_patient}
  def consume_patient_auth_code(code, chat_id_hash, opts) do
    kind = Keyword.fetch!(opts, :kind)
    used_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:auth_code, fn repo, _changes ->
      case fetch_by_code_and_kind_for_update(repo, code, kind) do
        nil -> {:error, :already_used}
        %__MODULE__{used_at: %DateTime{}} -> {:error, :already_used}
        auth_code -> {:ok, auth_code}
      end
    end)
    |> Ecto.Multi.run(:patient, fn repo, %{auth_code: auth_code} ->
      {:ok, repo.get!(Patient, auth_code.patient_id)}
    end)
    |> Ecto.Multi.update(:bind, fn %{patient: patient} ->
      Patient.changeset(patient, %{telegram_chat_id_hash: chat_id_hash})
    end)
    |> Ecto.Multi.update(:consume, fn %{auth_code: auth_code} ->
      changeset(auth_code, %{used_at: used_at})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{bind: patient}} ->
        {:ok, patient}

      {:error, :auth_code, :already_used, _changes} ->
        {:error, :already_used}

      {:error, :bind, %Ecto.Changeset{} = changeset, _changes} ->
        if chat_id_hash_taken?(changeset) do
          {:error, :chat_bound_to_other_patient}
        else
          {:error, changeset}
        end
    end
  end

  # ----------------------------------------------------------------
  # Rate limit
  # ----------------------------------------------------------------

  defp check_rate_limit(auth_code, ip) do
    now = DateTime.utc_now()

    same_window? =
      not is_nil(auth_code.last_attempt_ip) and auth_code.last_attempt_ip == ip and
        DateTime.diff(now, auth_code.updated_at, :second) < @rate_limit_window_seconds

    new_count = if same_window?, do: auth_code.attempt_count + 1, else: 1

    {:ok, _updated} =
      auth_code
      |> changeset(%{attempt_count: new_count, last_attempt_ip: ip})
      |> Repo.update()

    if new_count >= @rate_limit_max_attempts do
      :rate_limited
    else
      :ok
    end
  end

  # Rate-limit guard for a `code` that matches NO row — see moduledoc
  # "Guessing a code that matches no row". Tracks the attempt against a
  # borrowed stand-in row of the same `kind` (preferring one this `ip`
  # already touched) using the identical reactive threshold as
  # `check_rate_limit/2`.
  defp check_unmatched_rate_limit(ip, kind) when is_binary(ip) do
    case unmatched_tracking_row(ip, kind) do
      nil ->
        :expired

      auth_code ->
        now = DateTime.utc_now()

        same_window? =
          not is_nil(auth_code.last_attempt_ip) and auth_code.last_attempt_ip == ip and
            DateTime.diff(now, auth_code.updated_at, :second) < @rate_limit_window_seconds

        new_count = if same_window?, do: auth_code.attempt_count + 1, else: 1

        {:ok, _updated} =
          auth_code
          |> changeset(%{attempt_count: new_count, last_attempt_ip: ip})
          |> Repo.update()

        if new_count >= @rate_limit_max_attempts do
          :rate_limited
        else
          :expired
        end
    end
  end

  defp check_unmatched_rate_limit(_ip, _kind), do: :expired

  # Prefers a still-live row of this `kind` already tagged with `ip`
  # (so repeated wrong guesses from one IP accumulate on the SAME
  # row — this is the aggregate, IP+kind-scoped lookup that leans on
  # the same `(last_attempt_ip, ...)` shape the migration's index
  # targets). Falls back to the most recently minted still-live row of
  # the `kind` to bootstrap tracking for a brand-new attacking IP.
  defp unmatched_tracking_row(ip, kind) do
    case owned_tracking_row(ip, kind) do
      nil -> most_recent_live_row(kind)
      row -> row
    end
  end

  defp owned_tracking_row(ip, kind) do
    __MODULE__
    |> where([a], a.kind == ^kind and a.last_attempt_ip == ^ip and is_nil(a.used_at))
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp most_recent_live_row(kind) do
    __MODULE__
    |> where([a], a.kind == ^kind and is_nil(a.used_at))
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # ----------------------------------------------------------------
  # Lookup + eligibility helpers
  # ----------------------------------------------------------------

  defp fetch_by_code_and_kind(code, kind) do
    __MODULE__
    |> where([a], a.code == ^code and a.kind == ^kind)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # Same (code, kind) resolution as `fetch_by_code_and_kind/2`, but
  # with `FOR UPDATE` so two concurrent `consume_patient_auth_code/3`
  # calls for the same row serialize instead of racing — see moduledoc
  # "Row locking". Must run inside the enclosing `Ecto.Multi`
  # transaction for the lock to have any effect.
  defp fetch_by_code_and_kind_for_update(repo, code, kind) do
    __MODULE__
    |> where([a], a.code == ^code and a.kind == ^kind)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp chat_id_hash_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:telegram_chat_id_hash, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # ----------------------------------------------------------------
  # Code generation
  # ----------------------------------------------------------------

  defp generate_code("deep_link"), do: Alethea.Telegram.DeepLinkToken.mint()

  defp generate_code("six_digit") do
    (:rand.uniform(1_000_000) - 1)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  @type t :: %__MODULE__{}
end
