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

  test "the collision guard aborts loudly when rows would collide after canonicalization" do
    insert_raw!("guard@example.org")
    # Differs only by whitespace, which lower(email) alone does not fold.
    insert_raw!(" guard@example.org")

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(Alethea.Repo.Migrations.CanonicalizeProfessionalEmail.collision_guard_sql())
      end

    assert Exception.message(error) =~ "professionals.email has duplicates"
  end

  test "the collision guard passes when every email is distinct after canonicalization" do
    insert_raw!("distinct-one@example.org")
    insert_raw!("distinct-two@example.org")

    assert %Postgrex.Result{} =
             Repo.query!(
               Alethea.Repo.Migrations.CanonicalizeProfessionalEmail.collision_guard_sql()
             )
  end
end
