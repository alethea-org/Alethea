defmodule Alethea.Foundation.Accounts do
  @moduledoc """
  The v2 foundation accounts context.

  Wraps the three foundation schemas (`Professional`, `Patient`, `Admin`)
  behind a single public API. The schemas themselves expose the
  primary `register_professional/1`, `create_patient/2`,
  `update_patient/2`, and `register_admin/1` functions; this context
  is a thin re-export so future migrations and integrations have a
  single entry point.

  ## Boundary with legacy

  This module is part of the `Alethea.Foundation.*` parallel namespace.
  The legacy `Alethea.Accounts` continues to back the existing
  `professionals`/`patients` tables. Do not `alias` both
  `Alethea.Foundation.Accounts` and `Alethea.Accounts` from a single
  caller — the short-name collision will silently shadow the legacy
  module.

  See `openspec/sdd/bootstrap-alethea-v2/specs/accounts/spec.md` for
  the spec and `openspec/sdd/bootstrap-alethea-v2/02-design.md` for
  the architecture rationale.
  """

  alias Alethea.Foundation.Accounts.{Admin, Patient, PatientAuthCode, Professional}
  alias Alethea.Repo

  import Ecto.Query

  @doc """
  Registers a new professional. Delegates to
  `Alethea.Foundation.Accounts.Professional.register_professional/1`.
  """
  defdelegate register_professional(attrs), to: Professional

  @doc """
  Creates a new patient bound to the given professional. Delegates to
  `Alethea.Foundation.Accounts.Patient.create_patient/2`.
  """
  defdelegate create_patient(professional, attrs), to: Patient

  @doc """
  Updates an existing patient. Delegates to
  `Alethea.Foundation.Accounts.Patient.update_patient/2`.
  """
  defdelegate update_patient(patient, attrs), to: Patient

  @doc """
  Registers a new admin. Delegates to
  `Alethea.Foundation.Accounts.Admin.register_admin/1`.
  """
  defdelegate register_admin(attrs), to: Admin

  @doc """
  Lazy-provisions a foundation Professional from a legacy
  `Alethea.Accounts.Professional` (decision in #111, Option A — bridge
  the parallel identity namespaces without cutting over the auth path).

  The foundation professional is an **owner record only**: it carries
  the foundation-side foreign keys (patients, audit, etc.) while the
  legacy row keeps owning the credential. The foundation row is
  created by copying `email`, `full_name`, and the legacy
  `password_hash` **verbatim** — no re-hash, the plaintext was never
  available on this side, and a re-hash would invalidate the legacy
  credential. From that point on the foundation row is not a login
  surface; foundation auth remains dormant (see the `psicologo-foundation`
  follow-up change for the full unification).

  Idempotent: a second call with the same legacy professional returns
  the same foundation row without creating a duplicate. The unique
  index `foundation_professionals_legacy_professional_id_unique`
  enforces the "one foundation per legacy" invariant at the DB layer
  and makes the helper race-safe — two concurrent calls cannot
  create two foundation rows for the same legacy one; the second
  call falls through to a re-lookup that returns the winner's row.

  Returns `{:ok, %Professional{}}` on success, or
  `{:error, %Ecto.Changeset{}}` if the legacy row carries a missing
  or malformed `email` / `full_name` / `password_hash` (these are
  defensive — a healthy legacy row always has all three).
  """
  @spec find_or_provision_foundation_professional(Alethea.Accounts.Professional.t()) ::
          {:ok, Professional.t()} | {:error, Ecto.Changeset.t()}
  def find_or_provision_foundation_professional(%Alethea.Accounts.Professional{} = legacy) do
    case Repo.get_by(Professional, legacy_professional_id: legacy.id) do
      %Professional{} = foundation ->
        {:ok, foundation}

      nil ->
        case Professional.provision_foundation_professional(legacy) do
          {:ok, foundation} ->
            {:ok, foundation}

          # Race-safety: if a concurrent caller won the unique-index
          # race and inserted the row between our lookup and our
          # insert, the second insert fails with a unique violation
          # that is captured as a changeset error. Re-lookup picks
          # up the winning row; only the pathological case where
          # the row has vanished again propagates the changeset.
          {:error, %Ecto.Changeset{} = changeset} ->
            case Repo.get_by(Professional, legacy_professional_id: legacy.id) do
              %Professional{} = foundation -> {:ok, foundation}
              nil -> {:error, changeset}
            end
        end
    end
  end

  @valid_hash_byte_size 64

  @doc """
  Looks up a patient by their `telegram_chat_id_hash` (the HMAC-SHA256
  hex of the raw chat_id, 64 lowercase hex chars).

  Per `REQ-C2-lookup-by-hash`: returns `{:ok, %Patient{}}` for a
  bound hash, `:not_found` for everything else — including:

    - a hash no patient is bound to;
    - a raw chat_id (not 64 hex chars);
    - a non-hex string of the right length;
    - a `nil` or empty string.

  The function does NOT hash the input. Callers must hash the raw
  chat_id themselves (via `Alethea.Telegram.ChatIdHash.hash/2`) before
  calling `lookup_patient_by_chat_hash/1`. Hashing on the caller side
  keeps the boundary between "raw chat_id is the system's I/O surface"
  and "hash is the DB lookup key" auditable.

  ## PHI hygiene (R-1)

  No log line is emitted from this function. The hash itself is a
  PHI surface (it correlates the patient to a specific Telegram
  chat) and must not appear in logs. Caller-side error handling
  must NOT log the input hash.
  """
  @spec lookup_patient_by_chat_hash(any()) :: {:ok, Patient.t()} | :not_found
  def lookup_patient_by_chat_hash(hash)
      when is_binary(hash) and byte_size(hash) == @valid_hash_byte_size do
    case Repo.get_by(Patient, telegram_chat_id_hash: hash) do
      nil -> :not_found
      %Patient{} = patient -> {:ok, patient}
    end
  end

  def lookup_patient_by_chat_hash(_invalid_input) do
    # Any non-64-char-hex input is rejected at the API boundary as
    # `:not_found` — no false positive, no leakage of the validation
    # rule to the caller. This is the safe default: a caller that
    # passes a raw chat_id (the system's I/O surface) cannot trick
    # the lookup into returning a row.
    :not_found
  end

  @doc """
  Mints a fresh onboarding auth code for a patient. Delegates to
  `Alethea.Foundation.Accounts.PatientAuthCode.create_patient_auth_code/2`.
  """
  defdelegate create_patient_auth_code(patient_id, opts), to: PatientAuthCode

  @doc """
  Checks whether an onboarding auth code is eligible to be consumed.
  Delegates to
  `Alethea.Foundation.Accounts.PatientAuthCode.verify_patient_auth_code/3`.
  """
  defdelegate verify_patient_auth_code(code, ip, opts), to: PatientAuthCode

  @doc """
  Atomically binds a chat and consumes an onboarding auth code.
  Delegates to
  `Alethea.Foundation.Accounts.PatientAuthCode.consume_patient_auth_code/3`.
  """
  defdelegate consume_patient_auth_code(code, chat_id_hash, opts), to: PatientAuthCode

  @doc """
  Resolves the legacy `Alethea.Accounts.Patient` row that the given
  foundation Patient is bridged to via `legacy_patient_id`.

  Per REQ-C3-worker-resolves-patient + C-5, the Telegram worker
  resolves the inbound chat via `lookup_patient_by_chat_hash/1`
  (returns a foundation row) and then needs the legacy row to
  persist the `Message` (the `messages.patient_id` column references
  `patients.id`). This function is that bridge.

  Returns `{:ok, %Alethea.Accounts.Patient{}}` if the foundation row
  has `legacy_patient_id` set, `:not_linked` if it is `nil` (the
  foundation row exists but the patient has not been onboarded to the
  clinical pipeline), or `{:error, :legacy_not_found}` if the
  `legacy_patient_id` is set but the referenced legacy row is gone
  (deleted out from under the FK — possible because
  `on_delete: :nilify_all` only fires on the next write; until then
  the dangling FK is detectable here).

  ## PHI hygiene (R-1)

  No log line is emitted. The legacy patient id is an internal FK;
  the foundation Patient id is the public surface.
  """
  @spec legacy_patient(Patient.t()) ::
          {:ok, Alethea.Accounts.Patient.t()} | :not_linked | {:error, :legacy_not_found}
  def legacy_patient(%Patient{legacy_patient_id: nil}), do: :not_linked

  def legacy_patient(%Patient{legacy_patient_id: legacy_id}) do
    case Repo.get(Alethea.Accounts.Patient, legacy_id) do
      nil -> {:error, :legacy_not_found}
      %Alethea.Accounts.Patient{} = legacy -> {:ok, legacy}
    end
  end

  @doc """
  Resolves a foundation professional by email.

  Returns `{:ok, %Professional{}}` for a known email, `:not_found`
  otherwise. This is the foundation side of the legacy bridge used by
  `invite_patient_to_telegram/2`: the foundation and legacy tenants
  share no FK, so the professional is located by the email both
  systems persisted at registration time.

  ## PHI hygiene (R-1)

  No log line is emitted. The email is the lookup key, not the
  result.
  """
  @spec professional_by_email(String.t()) :: {:ok, Professional.t()} | :not_found
  def professional_by_email(email) when is_binary(email) do
    case Repo.get_by(Professional, email: email) do
      nil -> :not_found
      %Professional{} = professional -> {:ok, professional}
    end
  end

  @doc """
  Idempotently invites a legacy patient to Telegram by bridging them
  into the foundation tenant and minting the two onboarding codes.

  `legacy_patient_id` is the legacy `patients.id`; `foundation_pro`
  is the foundation professional (the caller's session tenant).

  ## Flow (one transaction)

  1. Resolve the legacy professional whose email matches the
     foundation professional's (the email bridge). No match →
     `{:error, :legacy_not_found}` — the professional has no legacy
     counterpart, so no legacy patient can exist for them (zero
     leakage across the two tenants).
  2. `FOR SHARE`-lock the legacy patient row, scoped to that legacy
     professional (`id` + `professional_id`). No such row →
     `{:error, :legacy_not_found}` (dangling id, or a patient that
     belongs to a DIFFERENT legacy professional — cross-tenant
     isolation).
  3. Find-or-create the foundation patient: one row per
     `(legacy_patient_id, foundation professional)` — the bridge
     (alias mirrored from the legacy row, `legacy_patient_id` set).
  4. Mint `deep_link` AND `six_digit` auth codes against the
     foundation patient via `PatientAuthCode.create_patient_auth_code/2`
     (same 10-minute TTL as the /start flow).

  Returns `{:ok, %{deep_link_token:, six_digit_code:, expires_at:,
  foundation_patient:}}` or `{:error, :legacy_not_found}` (dangling /
  cross-tenant / no legacy professional) or
  `{:error, %Ecto.Changeset{}}` (validation failure on the bridge
  insert or a code mint).

  ## Idempotency and concurrency (accepted limitation)

  The `FOR SHARE` lock serializes this transaction against a
  concurrent delete/update of the legacy row, but NOT against a
  concurrent sibling invite: two simultaneous invites for the same
  legacy patient both hold `FOR SHARE`, both observe no foundation
  row, and both insert. `legacy_patient_id` is intentionally NOT
  unique at the DB layer (a foundation admin tool may create rows
  before onboarding), so the duplicate window exists until a future
  unique index (see design `D2`); re-invites after either commit are
  idempotent.
  """
  @spec invite_patient_to_telegram(binary(), Professional.t()) ::
          {:ok,
           %{
             deep_link_token: String.t(),
             six_digit_code: String.t(),
             expires_at: DateTime.t(),
             foundation_patient: Patient.t()
           }}
          | {:error, :legacy_not_found | Ecto.Changeset.t()}
  def invite_patient_to_telegram(legacy_patient_id, %Professional{} = foundation_pro) do
    with {:ok, legacy_pro} <- legacy_professional_for(foundation_pro) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:legacy_patient, fn _repo, _changes ->
        case lock_legacy_patient(legacy_pro, legacy_patient_id) do
          nil -> {:error, :legacy_not_found}
          %Alethea.Accounts.Patient{} = legacy -> {:ok, legacy}
        end
      end)
      |> Ecto.Multi.run(:foundation_patient, fn _repo, %{legacy_patient: legacy} ->
        find_or_create_foundation_patient(legacy, foundation_pro)
      end)
      |> Ecto.Multi.run(:deep_link, fn _repo, %{foundation_patient: foundation_patient} ->
        mint_code(foundation_patient.id, "deep_link")
      end)
      |> Ecto.Multi.run(:six_digit, fn _repo, %{foundation_patient: foundation_patient} ->
        mint_code(foundation_patient.id, "six_digit")
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{foundation_patient: fp, deep_link: deep_link, six_digit: six_digit}} ->
          {:ok,
           %{
             deep_link_token: deep_link.code,
             six_digit_code: six_digit.code,
             expires_at: deep_link.expires_at,
             foundation_patient: fp
           }}

        {:error, :legacy_patient, :legacy_not_found, _changes} ->
          {:error, :legacy_not_found}

        {:error, _name, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Returns the Telegram connection status for a single legacy patient
  under the given foundation professional's scope.

  Returns:
    - `:connected` — a foundation row exists, scoped to this
      professional, with `telegram_chat_id_hash` set (the /start bind
      flow completed).
    - `:not_connected` — no scoped foundation row yet, or one that has
      not been bound (hash `nil`).
    - `{:error, :legacy_not_found}` — the foundation professional has
      no legacy counterpart, OR the legacy patient does not exist /
      belongs to a different legacy professional (cross-tenant).

  ## PHI hygiene (R-1)

  No log line is emitted. The status is derived from the hash column,
  never from a raw chat_id.
  """
  @spec telegram_connection_status(binary(), Professional.t()) ::
          :connected | :not_connected | {:error, :legacy_not_found}
  def telegram_connection_status(legacy_patient_id, %Professional{} = foundation_pro) do
    case legacy_professional_for(foundation_pro) do
      {:error, :legacy_not_found} = error ->
        error

      {:ok, legacy_pro} ->
        case Repo.get_by(Alethea.Accounts.Patient,
               id: legacy_patient_id,
               professional_id: legacy_pro.id
             ) do
          nil ->
            {:error, :legacy_not_found}

          %Alethea.Accounts.Patient{} ->
            case Repo.get_by(Patient,
                   legacy_patient_id: legacy_patient_id,
                   professional_id: foundation_pro.id
                 ) do
              nil -> :not_connected
              %Patient{telegram_chat_id_hash: nil} -> :not_connected
              %Patient{telegram_chat_id_hash: hash} when is_binary(hash) -> :connected
            end
        end
    end
  end

  @doc """
  Returns the Telegram connection status for many legacy patient ids
  under the given foundation professional's scope, as
  `%{legacy_patient_id => :connected | :not_connected}`.

  Resolves the whole batch with a SINGLE query against
  `foundation_patients` (one `IN` clause, scoped by this
  professional's `professional_id`) — no N+1. An id with no scoped
  foundation row maps to `:not_connected`; an id outside this
  professional's tenant NEVER surfaces another tenant's state (it maps
  to `:not_connected`). Unlike `telegram_connection_status/2` this
  function never errors — it is the dashboard-facing list primitive,
  where a badge is always renderable.

  ## PHI hygiene (R-1)

  No log line is emitted. Only the presence of the hash column is
  read.
  """
  @spec telegram_connection_statuses([binary()], Professional.t()) :: %{
          binary() => :connected | :not_connected
        }
  def telegram_connection_statuses(legacy_patient_ids, %Professional{} = foundation_pro)
      when is_list(legacy_patient_ids) do
    connected_ids =
      Patient
      |> where([p], p.legacy_patient_id in ^legacy_patient_ids)
      |> where([p], p.professional_id == ^foundation_pro.id)
      |> where([p], not is_nil(p.telegram_chat_id_hash))
      |> select([p], p.legacy_patient_id)
      |> Repo.all()

    connected_set = MapSet.new(connected_ids)

    Map.new(legacy_patient_ids, fn id ->
      {id, if(MapSet.member?(connected_set, id), do: :connected, else: :not_connected)}
    end)
  end

  # Resolves the legacy professional whose email matches the
  # foundation professional's (D1: the email bridge). Returns
  # `{:error, :legacy_not_found}` when no legacy counterpart exists —
  # deliberately NOT `:not_found`, so a caller cannot distinguish "no
  # legacy pro" from "no legacy patient" (zero leakage).
  defp legacy_professional_for(%Professional{email: email}) when is_binary(email) do
    case Repo.get_by(Alethea.Accounts.Professional, email: email) do
      nil -> {:error, :legacy_not_found}
      %Alethea.Accounts.Professional{} = legacy_pro -> {:ok, legacy_pro}
    end
  end

  # Locks the legacy patient row for the duration of the enclosing
  # transaction, scoped to the legacy professional's tenant. `FOR
  # SHARE` (not `FOR UPDATE`): the invite never mutates the legacy
  # row, and it must not block legitimate legacy writes — it only
  # serializes against a concurrent delete/update of the very row
  # being bridged. A shared lock does NOT serialize two concurrent
  # invites of the same patient (see the `invite_patient_to_telegram/2`
  # docstring, "Idempotency and concurrency").
  defp lock_legacy_patient(%Alethea.Accounts.Professional{id: legacy_pro_id}, legacy_patient_id) do
    Alethea.Accounts.Patient
    |> where([p], p.id == ^legacy_patient_id and p.professional_id == ^legacy_pro_id)
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  # One foundation patient per (legacy_patient_id, foundation
  # professional). The alias is mirrored from the legacy row so the
  # foundation UI shows the same anonymized display name.
  defp find_or_create_foundation_patient(
         %Alethea.Accounts.Patient{alias: alias, id: legacy_id},
         %Professional{} = foundation_pro
       ) do
    case Repo.get_by(Patient, legacy_patient_id: legacy_id, professional_id: foundation_pro.id) do
      nil ->
        Patient.create_patient(foundation_pro, %{
          alias: alias,
          legacy_patient_id: legacy_id
        })

      %Patient{} = foundation_patient ->
        {:ok, foundation_patient}
    end
  end

  defp mint_code(patient_id, kind) do
    case PatientAuthCode.create_patient_auth_code(patient_id, kind: kind) do
      {:ok, %PatientAuthCode{} = code} -> {:ok, code}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end
end
