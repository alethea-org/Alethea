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
  Provisions (find-or-creates) the legacy patient's Telegram-native
  identity row in the foundation schema, then mints both invite
  kinds (deep_link + six_digit) and returns them for display.

  Per #108 acceptance criteria:

    - The foundation row is bridged to the legacy patient via
      `legacy_patient_id` (no orphan rows).
    - The foundation row mirrors the legacy `alias` so the
      Telegram identity inherits the same display name.
    - The row is scoped to the acting professional — the
      `professional_id` is set programmatically (not via the cast
      list), matching the existing
      `Alethea.Foundation.Accounts.Patient.create_patient/2`
      tenant boundary.
    - Calling it again for the same legacy patient REUSES the
      existing foundation row — `legacy_patient_id` is the natural
      idempotency key. The `(patient_id, code, kind)` unique index
      on `foundation_patient_auth_codes` is unaffected because each
      mint is a fresh code.
    - The 10-minute TTL on the auth code is unchanged (the
      underlying `create_patient_auth_code/2` still uses the
      existing `@ttl_seconds = 600`).
    - No raw `chat_id` ever touches the foundation row here — only
      the eventual `/start` bind step writes
      `telegram_chat_id_hash`, and only as a one-way HMAC.

  Returns `{:ok, %{patient: %Patient{}, deep_link: code,
  six_digit: code, expires_at: DateTime.t()}}` on success. Returns
  `{:error, :tenant_mismatch}` when the legacy patient and the
  professional disagree on `professional_id` (the caller is trying
  to act across the tenant boundary — fail loud, fail closed).

  ## PHI hygiene (R-1)

  No log line is emitted. The minted codes are bearer secrets for
  the patient onboarding flow; they must never appear in logs.
  Caller-side error handling must NOT log the returned codes.
  """
  @spec invite_to_telegram(
          Alethea.Accounts.Patient.t(),
          Alethea.Accounts.Professional.t()
        ) ::
          {:ok, %{patient: Patient.t(), deep_link: String.t(), six_digit: String.t(), expires_at: DateTime.t()}}
          | {:error, :tenant_mismatch | Ecto.Changeset.t()}
  def invite_to_telegram(
        %Alethea.Accounts.Patient{professional_id: pro_id, alias: legacy_alias, id: legacy_id},
        %Alethea.Accounts.Professional{id: pro_id}
      ) when is_binary(legacy_alias) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:foundation_patient, fn repo, _changes ->
      case repo.get_by(Patient, legacy_patient_id: legacy_id) do
        nil ->
          %Patient{}
          |> Patient.changeset(%{
            alias: legacy_alias,
            legacy_patient_id: legacy_id,
            status: "active"
          })
          |> Ecto.Changeset.put_change(:professional_id, pro_id)
          |> repo.insert()

        %Patient{} = existing ->
          {:ok, existing}
      end
    end)
    |> Ecto.Multi.run(:deep_link, fn _repo, %{foundation_patient: fp} ->
      PatientAuthCode.create_patient_auth_code(fp.id, kind: "deep_link")
    end)
    |> Ecto.Multi.run(:six_digit, fn _repo, %{foundation_patient: fp} ->
      PatientAuthCode.create_patient_auth_code(fp.id, kind: "six_digit")
    end)
    |> Ecto.Multi.run(:invite, fn _repo, %{foundation_patient: fp, deep_link: dl, six_digit: sd} ->
      {:ok,
       %{
         patient: fp,
         deep_link: dl.code,
         six_digit: sd.code,
         expires_at: dl.expires_at
       }}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invite: invite}} -> {:ok, invite}
      {:error, _step, error, _changes} -> {:error, error}
    end
  end

  def invite_to_telegram(
        %Alethea.Accounts.Patient{} = _legacy_patient,
        %Alethea.Accounts.Professional{} = _professional
      ) do
    # Mismatched tenant boundary: the legacy patient belongs to a
    # different professional than the actor. Fail closed — the
    # caller should never see an invite minted across tenants.
    {:error, :tenant_mismatch}
  end

  @doc """
  Returns `true` if the legacy patient has a bound Telegram
  identity (their foundation row exists AND has
  `telegram_chat_id_hash` set), `false` otherwise.

  Per #108: the dashboard shows a light connected/not-connected
  indicator derived from the Telegram identity hash. The check is
  scoped to the legacy patient's `legacy_patient_id` bridge, so the
  indicator is per-patient, not per-professional-roster.

  Returns `false` for any non-legacy-patient input (defensive
  guard).

  ## PHI hygiene (R-1)

  No log line is emitted. The hash itself is a PHI surface (it
  correlates the patient to a specific Telegram chat); checking
  its presence must not appear in logs.
  """
  @spec telegram_connected?(Alethea.Accounts.Patient.t()) :: boolean()
  def telegram_connected?(%Alethea.Accounts.Patient{id: legacy_id})
      when is_binary(legacy_id) do
    case Repo.get_by(Patient, legacy_patient_id: legacy_id) do
      %Patient{telegram_chat_id_hash: hash} when is_binary(hash) -> true
      _ -> false
    end
  end

  def telegram_connected?(_), do: false
end
