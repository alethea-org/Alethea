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

  alias Alethea.Foundation.Accounts.{Admin, Patient, Professional}
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
end
