defmodule Alethea.Repo.Migrations.CanonicalizeProfessionalEmail do
  @moduledoc """
  Makes `professionals.email` a canonical identity (security-audit-run-1, S3).

  `up/0`:

    1. Aborts with a clear error, before changing anything, when two rows
       would collide once their emails are canonicalized exactly like
       `Alethea.Accounts.Professional.normalize_email/1` (Unicode-aware
       trim, then downcase). It never merges or deletes accounts: an
       operator must resolve the duplicates first.
    2. Rewrites every non-canonical row to that canonical form.
    3. Replaces the case-sensitive unique index with a unique index on
       `lower(email)`, keeping the name `professionals_email_index` that
       `Professional.changeset/2`'s `unique_constraint(:email)` expects.

  `down/0` restores the original case-sensitive index. The emails stay
  canonicalized: the original casing is not recoverable, and lowercase
  emails are valid under the old index too.
  """

  use Ecto.Migration

  @doc false
  # Canonicalizes in Elixir with exactly the steps of
  # `Alethea.Accounts.Professional.normalize_email/1` (inlined so this
  # migration never depends on application code that may change later).
  # SQL `trim()` only strips ASCII spaces, so it would leave e.g. a
  # trailing no-break space that the application's lookup strips, and
  # that account could no longer sign in.
  def canonicalize_emails!(repo) do
    %{rows: rows} = repo.query!("SELECT id, email FROM professionals")

    planned = Enum.map(rows, fn [id, email] -> {id, email, canonical(email)} end)

    collisions =
      planned
      |> Enum.group_by(fn {_id, _email, canonical} -> canonical end)
      |> Enum.count(fn {_canonical, group} -> length(group) > 1 end)

    if collisions > 0 do
      raise "professionals.email has duplicates after canonicalization: " <>
              "#{collisions} colliding address(es). Resolve them manually before " <>
              "migrating; this migration never merges or deletes accounts."
    end

    for {id, email, canonical} <- planned, email != canonical do
      repo.query!("UPDATE professionals SET email = $1 WHERE id = $2", [canonical, id])
    end

    :ok
  end

  defp canonical(email), do: email |> String.trim() |> String.downcase()

  def up do
    canonicalize_emails!(repo())

    drop index(:professionals, [:email], name: :professionals_email_index)

    create unique_index(:professionals, ["lower(email)"], name: :professionals_email_index)
  end

  def down do
    drop index(:professionals, ["lower(email)"], name: :professionals_email_index)

    create unique_index(:professionals, [:email], name: :professionals_email_index)
  end
end
