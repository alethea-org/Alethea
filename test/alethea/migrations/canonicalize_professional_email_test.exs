defmodule Alethea.Migrations.CanonicalizeProfessionalEmailTest do
  @moduledoc """
  S3 (security-audit-run-1): `CanonicalizeProfessionalEmail` makes
  `professionals.email` unique case-insensitively at the database level
  and refuses to run when existing rows would collide after
  canonicalization, instead of silently merging accounts.

  The test database is migrated once at suite boot, so these tests
  assert the post-migration index directly and run the migration's
  collision guard SQL against rows inserted in the sandbox (migration
  files are not compiled by `mix test`, so the file is required here).
  """

  use Alethea.DataCase, async: true

  alias Alethea.Accounts.Professional

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261125175946_canonicalize_professional_email.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  defp insert_raw!(email) do
    # Bypasses the changeset on purpose: only the database index stands
    # between this insert and a duplicate identity.
    Repo.insert!(%Professional{email: email, full_name: "Raw", password_hash: "x"})
  end

  test "the database rejects a case variant of an existing email even without the changeset" do
    insert_raw!("index@example.org")

    assert_raise Ecto.ConstraintError, ~r/professionals_email_index/, fn ->
      insert_raw!("INDEX@Example.org")
    end
  end

  alias Alethea.Repo.Migrations.CanonicalizeProfessionalEmail, as: Migration

  test "canonicalization aborts loudly when rows would collide, before changing anything" do
    insert_raw!("guard@example.org")
    # Differs only by whitespace, which lower(email) alone does not fold.
    insert_raw!(" guard@example.org")

    error = assert_raise RuntimeError, fn -> Migration.canonicalize_emails!(Repo) end

    assert Exception.message(error) =~ "professionals.email has duplicates"
    assert Repo.get_by(Professional, email: " guard@example.org")
  end

  test "Unicode whitespace that normalize_email/1 strips is folded too" do
    # A trailing no-break space passes the old format check; SQL trim()
    # would leave it in place while the app's lookup strips it.
    insert_raw!("nbsp@example.org\u00A0")
    insert_raw!("plain@example.org")
    insert_raw!("\u00A0plain@example.org")

    error = assert_raise RuntimeError, fn -> Migration.canonicalize_emails!(Repo) end
    assert Exception.message(error) =~ "1 colliding address"
  end

  test "rows are rewritten to exactly Professional.normalize_email/1" do
    raw = ["\u00A0Nbsp@Example.org\u00A0", " Mixed@Example.ORG ", "JOSÉ@Example.org"]
    rows = Enum.map(raw, &insert_raw!/1)

    assert :ok = Migration.canonicalize_emails!(Repo)

    for {row, email} <- Enum.zip(rows, raw) do
      assert Repo.get!(Professional, row.id).email == Professional.normalize_email(email)
    end

    assert %Professional{} = Alethea.Accounts.get_professional_by_email("nbsp@example.org")
  end
end
