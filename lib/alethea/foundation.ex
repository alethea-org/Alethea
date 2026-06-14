defmodule Alethea.Foundation do
  @moduledoc """
  Namespace marker for the `Alethea.Foundation.*` parallel module tree.

  ## Boundary with legacy

  Everything under `Alethea.Foundation.*` is the **v2 foundation**: clean
  modules added alongside the legacy `Alethea.*` tree. The legacy code
  continues to back the existing tables and the existing 223-test
  baseline. Future changes migrate the legacy to the foundation one
  slice at a time. Until that migration is complete, do NOT `alias`
  both `Alethea.Foundation.Accounts` and `Alethea.Accounts` from a
  single caller — the short name collision will silently shadow the
  legacy.

  ## What lives here

  - `Alethea.Foundation.Accounts.{Professional,Patient,Admin}` — the
    canonical Ecto schemas for the three roles, with field names from
    `openspec/UBIQUITOUS_LANGUAGE.md`.
  - `Alethea.Foundation.Accounts` — the public context module wrapping
    the three schemas.
  - `Alethea.Foundation.Tenant` — the `scope_query/2` tenant primitive.
  - `Alethea.Foundation.Encryption.KEK` — KEK/DEK envelope primitive
    (added in a later PR).

  See `openspec/sdd/bootstrap-alethea-v2/specs/accounts/spec.md` for
  the spec and `openspec/sdd/bootstrap-alethea-v2/02-design.md` for
  the architecture rationale.
  """
end
