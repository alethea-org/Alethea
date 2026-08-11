defmodule Alethea.Repo.Migrations.AddLegacyProfessionalIdToFoundationProfessionals do
  @moduledoc """
  Adds the `legacy_professional_id` foreign key to
  `foundation_professionals`, bridging the foundation v2 identity row to
  the legacy `professionals` row that backs the dashboard login.

  ## Why this column exists (decision in #111 — Option A)

  The foundation patient invite action (issue #108, blocked by this
  ticket) creates a `foundation_patients` row whose `professional_id`
  must reference a `foundation_professionals` row. The foundation
  professional is, however, not yet a first-class concept the user logs
  in with: the legacy `professionals` table still owns the dashboard
  session, and the foundation login surface is dormant. The bridge is
  the thin seam that lets the foundation schema carry the
  foundation-side foreign keys (patients, audit) while the legacy
  table keeps owning the credential.

  The chosen bridge is **lazy provisioning**: the foundation
  professional row is created the first time the system needs one for
  a given legacy professional, copying `email`, `full_name`, and the
  legacy `password_hash` **verbatim** (no re-hash — the plaintext was
  never available on this side, and a re-hash would invalidate the
  legacy credential). From that point on the foundation row is an
  **owner record only** — no auth path, no KEK cutover, no
  token migration.

  See `Alethea.Foundation.Accounts.find_or_provision_foundation_professional/1`
  for the helper that materializes this row on demand.

  ## Unique index

  The bridge is "one foundation professional per legacy professional".
  The unique index `foundation_professionals_legacy_professional_id_unique`
  enforces that at the DB layer, which makes the
  `find_or_provision/1` helper race-safe: two concurrent calls cannot
  create two foundation rows for the same legacy one — the second
  insert hits the unique violation and falls through to the
  re-lookup path that resolves to the row the first call won.

  ## Nullable + no backfill

  Existing `foundation_professionals` rows pre-date the bridge and
  were created via `register_professional/1` with their own plaintext
  password, not by lazy provisioning from a legacy row. The column is
  `null: true` and no backfill is attempted: a foundation row without
  a `legacy_professional_id` is a row whose foundation login surface
  was registered before the bridge existed (or by foundation admin
  tooling that mints a fresh credential).

  ## Boundary with legacy

  The `professionals` table has no `on_delete: :delete_all` from a
  foundation child — the inverse — "what happens to the foundation
  row when the legacy row is deleted" — is intentionally
  `on_delete: :nilify_all`. Deleting a legacy professional (admin
  tooling, GDPR right-to-erasure) must not cascade-delete the
  foundation identity row. The clinical record is purged; the
  identity record remains so future re-onboarding can re-link.
  """

  use Ecto.Migration

  def change do
    alter table(:foundation_professionals) do
      add :legacy_professional_id,
          references(:professionals, on_delete: :nilify_all, type: :binary_id)
    end

    # The "one foundation per legacy" invariant for the lazy
    # provisioning bridge. The unique index doubles as the lookup
    # index for `Repo.get_by(Professional, legacy_professional_id: ...)`,
    # so no separate non-unique index is needed (the patient bridge
    # migration has a non-unique index because the patient side has
    # no such invariant; the professional side does).
    create unique_index(
      :foundation_professionals,
      [:legacy_professional_id],
      name: :foundation_professionals_legacy_professional_id_unique
    )
  end
end
