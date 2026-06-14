defmodule Alethea.Foundation.Tenant do
  @moduledoc """
  The tenant-scope helper for the foundation namespace.

  ## Tenant = Psicólogo (per UBIQUITOUS_LANGUAGE.md)

  Each `Psicólogo` is a tenant. The tenant boundary in Alethea is a
  single FK column (`professional_id`) on every table that holds
  patient data. This module provides the `scope_query/2` primitive
  that filters any Ecto query by `professional_id`.

  ## Dual-schema acceptance

  The helper uses `Ecto.Queryable` duck-typing. It accepts BOTH the
  legacy `Alethea.Accounts.Patient` (which is in active use behind
  the legacy `patients` table) and the foundation
  `Alethea.Foundation.Accounts.Patient` (which is the new
  `foundation_patients` table). Both schemas expose a
  `professional_id` column on their query, so the `where` clause
  compiles against either. A future change (`legacy-cleanup`) will
  retire the legacy schema; until then both are supported.

  ## UUID validation

  The helper does NOT validate that `professional_id` is a UUID. The
  spec explicitly defers UUID validation to the caller (the auth/live
  session layer that hands us the professional_id from a verified
  session). At this layer, a non-UUID binary is accepted.
  """

  import Ecto.Query

  @type professional_id :: binary()

  @doc """
  Returns a new Ecto query that filters the given queryable by
  `professional_id`.

  Raises `ArgumentError` if `professional_id` is `nil`.
  """
  @spec scope_query(Ecto.Queryable.t(), professional_id()) :: Ecto.Query.t()
  def scope_query(queryable, professional_id) when is_binary(professional_id) do
    queryable
    |> Ecto.Queryable.to_query()
    |> where([row], row.professional_id == ^professional_id)
  end

  def scope_query(_queryable, nil) do
    raise ArgumentError, "professional_id must not be nil"
  end
end
