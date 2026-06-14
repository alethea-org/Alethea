defmodule Alethea.Foundation.TenantTest do
  # We use Alethea.DataCase for the sandboxed DB test (3rd one), and
  # the rest are pure-function checks on the query structure.
  use Alethea.DataCase, async: true

  import Ecto.Query

  alias Alethea.Foundation.Accounts.{Patient, Professional}
  alias Alethea.Foundation.Tenant

  describe "scope_query/2 — filters by tenant" do
    test "returns a query that filters patients by professional_id" do
      query = from(p in Patient)
      scoped = Tenant.scope_query(query, "prof-uuid-1")

      # The query must contain a WHERE clause
      assert %Ecto.Query{wheres: [_ | _]} = scoped

      # The parameter binding for the professional_id is captured
      assert scoped.params == ["prof-uuid-1"]
    end

    test "executes against the test repo and returns only matching patients" do
      pro =
        Repo.insert!(%Professional{
          email: "scope-#{System.unique_integer([:positive])}@example.com",
          password_hash: Pbkdf2.hash_pwd_salt("supersecret12"),
          full_name: "Scope Pro"
        })

      other_pro =
        Repo.insert!(%Professional{
          email: "scope-other-#{System.unique_integer([:positive])}@example.com",
          password_hash: Pbkdf2.hash_pwd_salt("supersecret12"),
          full_name: "Other Pro"
        })

      p1 = Repo.insert!(%Patient{alias: "P1", professional_id: pro.id})
      p2 = Repo.insert!(%Patient{alias: "P2", professional_id: pro.id})
      _p3 = Repo.insert!(%Patient{alias: "P3", professional_id: other_pro.id})

      results = Patient |> Tenant.scope_query(pro.id) |> Repo.all()
      ids = Enum.map(results, & &1.id) |> Enum.sort()

      assert ids == Enum.sort([p1.id, p2.id])
    end
  end

  describe "scope_query/2 — rejects nil" do
    test "raises ArgumentError when professional_id is nil" do
      assert_raise ArgumentError, "professional_id must not be nil", fn ->
        Tenant.scope_query(from(p in Patient), nil)
      end
    end
  end

  describe "scope_query/2 — non-UUID binary" do
    test "accepts a non-UUID binary (validation is upstream)" do
      query = from(p in Patient)
      scoped = Tenant.scope_query(query, "not-a-uuid")

      assert %Ecto.Query{wheres: [_ | _]} = scoped
      assert scoped.params == ["not-a-uuid"]
    end
  end
end
