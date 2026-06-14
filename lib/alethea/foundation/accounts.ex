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
end
