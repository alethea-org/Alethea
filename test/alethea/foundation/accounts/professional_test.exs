defmodule Alethea.Foundation.Accounts.ProfessionalTest do
  use Alethea.DataCase, async: true

  alias Alethea.Accounts, as: Legacy
  alias Alethea.Foundation.Accounts.Professional

  @valid_password "supersecret12"

  describe "register_professional/1 — happy path" do
    test "persists a professional with email, password_hash, id, and timestamps" do
      attrs = %{
        email: "ana@example.com",
        password: @valid_password,
        full_name: "Ana Pérez"
      }

      assert {:ok, %Professional{} = professional} = Professional.register_professional(attrs)

      assert professional.email == "ana@example.com"
      assert professional.full_name == "Ana Pérez"
      assert is_binary(professional.password_hash)
      refute professional.password_hash == @valid_password
      assert is_binary(professional.id)
      assert %DateTime{} = professional.inserted_at
      assert %DateTime{} = professional.updated_at
    end

    test "register_professional/1 does not bind a legacy_professional_id" do
      # The bridge column is reserved for `provision_foundation_professional/1`
      # — a fresh registration carries no legacy link.
      attrs = %{
        email: "no-bridge-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        full_name: "No Bridge"
      }

      assert {:ok, %Professional{} = professional} = Professional.register_professional(attrs)
      assert professional.legacy_professional_id == nil
    end
  end

  describe "register_professional/1 — validation" do
    test "rejects duplicate email with an :email error" do
      base_attrs = %{
        email: "dup@example.com",
        password: @valid_password,
        full_name: "Ana Pérez"
      }

      assert {:ok, _first} = Professional.register_professional(base_attrs)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Professional.register_professional(base_attrs)

      assert %{email: [_ | _]} = errors_on(changeset)
    end

    test "rejects an invalid email format" do
      attrs = %{
        email: "not-an-email",
        password: @valid_password,
        full_name: "Ana Pérez"
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Professional.register_professional(attrs)

      assert %{email: [_ | _]} = errors_on(changeset)
    end

    test "rejects a password shorter than 12 characters" do
      attrs = %{
        email: "short@example.com",
        password: "short",
        full_name: "Ana Pérez"
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Professional.register_professional(attrs)

      assert %{password: [_ | _]} = errors_on(changeset)
    end
  end

  describe "password hashing" do
    test "the persisted hash round-trips through Pbkdf2.verify_pass/2" do
      password = @valid_password

      {:ok, professional} =
        Professional.register_professional(%{
          email: "hash-#{System.unique_integer([:positive])}@example.com",
          password: password,
          full_name: "Hash Test"
        })

      assert Pbkdf2.verify_pass(password, professional.password_hash)
      refute Pbkdf2.verify_pass("wrong-password", professional.password_hash)
    end
  end

  describe "provision_foundation_professional/1 — bridge from the legacy row (decision #111, Option A)" do
    test "copies email, full_name, and password_hash from the legacy row verbatim" do
      {:ok, legacy} =
        Legacy.create_professional(%{
          email: "bridge-copy-#{System.unique_integer([:positive])}@example.com",
          full_name: "Bridge Copy Pro",
          password: @valid_password
        })

      assert {:ok, %Professional{} = foundation} =
               Professional.provision_foundation_professional(legacy)

      assert foundation.email == legacy.email
      assert foundation.full_name == legacy.full_name

      # The hash is a byte-for-byte copy of the legacy hash. We deliberately
      # do NOT re-hash — the plaintext was never available on this side, and
      # a re-hash would invalidate the legacy credential (see migration
      # moduledoc for the rationale).
      assert foundation.password_hash == legacy.password_hash
    end

    test "the copied hash validates via Pbkdf2.verify_pass against the legacy password" do
      password = @valid_password

      {:ok, legacy} =
        Legacy.create_professional(%{
          email: "bridge-verify-#{System.unique_integer([:positive])}@example.com",
          full_name: "Bridge Verify Pro",
          password: password
        })

      assert {:ok, %Professional{} = foundation} =
               Professional.provision_foundation_professional(legacy)

      assert Pbkdf2.verify_pass(password, foundation.password_hash)
      refute Pbkdf2.verify_pass("not-the-password", foundation.password_hash)
    end

    test "the foundation row links back to the legacy professional via legacy_professional_id" do
      {:ok, legacy} =
        Legacy.create_professional(%{
          email: "bridge-link-#{System.unique_integer([:positive])}@example.com",
          full_name: "Bridge Link Pro",
          password: @valid_password
        })

      assert {:ok, %Professional{} = foundation} =
               Professional.provision_foundation_professional(legacy)

      assert foundation.legacy_professional_id == legacy.id
    end

    test "the foundation row carries its own id and timestamps, distinct from the legacy row" do
      {:ok, legacy} =
        Legacy.create_professional(%{
          email: "bridge-ids-#{System.unique_integer([:positive])}@example.com",
          full_name: "Bridge Ids Pro",
          password: @valid_password
        })

      assert {:ok, %Professional{} = foundation} =
               Professional.provision_foundation_professional(legacy)

      assert is_binary(foundation.id)
      refute foundation.id == legacy.id
      assert %DateTime{} = foundation.inserted_at
      assert %DateTime{} = foundation.updated_at
    end

    test "rejects a legacy professional with missing required fields" do
      # A blank-by-design legacy row (no email / full_name / password_hash) —
      # the validate_required/2 guard catches it at the boundary instead of
      # letting a half-populated foundation row leak through.
      broken_legacy = %Legacy.Professional{
        id: Ecto.UUID.generate(),
        email: nil,
        full_name: nil,
        password_hash: nil
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               Professional.provision_foundation_professional(broken_legacy)

      assert %{email: [_ | _]} = errors_on(changeset)
      assert %{full_name: [_ | _]} = errors_on(changeset)
      assert %{password_hash: [_ | _]} = errors_on(changeset)
    end

    test "rejects a legacy professional with a malformed email" do
      broken_legacy = %Legacy.Professional{
        id: Ecto.UUID.generate(),
        email: "not-an-email",
        full_name: "Bridge Email Pro",
        password_hash: "not-a-real-pbkdf2-hash-but-present"
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               Professional.provision_foundation_professional(broken_legacy)

      assert %{email: [_ | _]} = errors_on(changeset)
    end

    test "rejects a second foundation row for the same legacy_professional_id at the DB layer" do
      # The unique index `foundation_professionals_legacy_professional_id_unique`
      # is the DB-side guard for the "one foundation per legacy" invariant.
      # Even bypassing the helper, the second insert must fail.
      {:ok, legacy} =
        Legacy.create_professional(%{
          email: "bridge-unique-#{System.unique_integer([:positive])}@example.com",
          full_name: "Bridge Unique Pro",
          password: @valid_password
        })

      assert {:ok, %Professional{} = first} =
               Professional.provision_foundation_professional(legacy)

      # A second insert for the same legacy_professional_id collides with
      # the unique index. We use the changeset path so the violation is
      # converted to a changeset error rather than a raised exception
      # (the schema's unique_constraint/2 on `legacy_professional_id` is
      # what makes that conversion happen).
      duplicate_attrs = %{
        email: "bridge-unique-2-#{System.unique_integer([:positive])}@example.com",
        full_name: "Bridge Unique 2",
        password_hash: first.password_hash,
        legacy_professional_id: legacy.id
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               %Professional{}
               |> Ecto.Changeset.change(duplicate_attrs)
               |> Ecto.Changeset.validate_required([:email, :full_name, :password_hash])
               |> Ecto.Changeset.unique_constraint(:legacy_professional_id,
                 name: :foundation_professionals_legacy_professional_id_unique
               )
               |> Alethea.Repo.insert()

      assert %{legacy_professional_id: [_ | _]} = errors_on(changeset)
    end
  end
end
