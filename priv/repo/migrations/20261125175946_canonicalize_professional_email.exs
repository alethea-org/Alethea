defmodule Alethea.Repo.Migrations.CanonicalizeProfessionalEmail do
  @moduledoc """
  Makes `professionals.email` a canonical identity (security-audit-run-1, S3).

  `up/0`:

    1. Aborts with a clear error when two rows would collide once their
       emails are trimmed and lowercased. It never merges or deletes
       accounts: an operator must resolve the duplicates first, e.g. by
       inspecting `SELECT lower(trim(email)), count(*) FROM professionals
       GROUP BY 1 HAVING count(*) > 1`.
    2. Canonicalizes existing rows to `lower(trim(email))`, matching
       `Alethea.Accounts.Professional.normalize_email/1`.
    3. Replaces the case-sensitive unique index with a unique index on
       `lower(email)`, keeping the name `professionals_email_index` that
       `Professional.changeset/2`'s `unique_constraint(:email)` expects.

  `down/0` restores the original case-sensitive index. The emails stay
  canonicalized: the original casing is not recoverable, and lowercase
  emails are valid under the old index too.
  """

  use Ecto.Migration

  @doc false
  def collision_guard_sql do
    """
    DO $$
    DECLARE
      duplicates integer;
    BEGIN
      SELECT count(*) INTO duplicates FROM (
        SELECT lower(trim(email)) FROM professionals GROUP BY 1 HAVING count(*) > 1
      ) AS collisions;

      IF duplicates > 0 THEN
        RAISE EXCEPTION 'professionals.email has duplicates after lower(trim(email)): % colliding address(es). Resolve them manually before migrating; this migration never merges or deletes accounts.', duplicates;
      END IF;
    END
    $$;
    """
  end

  def up do
    execute(collision_guard_sql())

    execute("""
    UPDATE professionals SET email = lower(trim(email))
    WHERE email <> lower(trim(email))
    """)

    drop index(:professionals, [:email], name: :professionals_email_index)

    create unique_index(:professionals, ["lower(email)"], name: :professionals_email_index)
  end

  def down do
    drop index(:professionals, ["lower(email)"], name: :professionals_email_index)

    create unique_index(:professionals, [:email], name: :professionals_email_index)
  end
end
