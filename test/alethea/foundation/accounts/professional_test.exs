defmodule Alethea.Foundation.Accounts.ProfessionalTest do
  use Alethea.DataCase, async: true

  alias Alethea.Foundation.Accounts.Professional

  describe "register_professional/1 — happy path" do
    test "persists a professional with email, password_hash, id, and timestamps" do
      attrs = %{
        email: "ana@example.com",
        password: "supersecret12",
        full_name: "Ana Pérez"
      }

      assert {:ok, %Professional{} = professional} = Professional.register_professional(attrs)

      assert professional.email == "ana@example.com"
      assert professional.full_name == "Ana Pérez"
      assert is_binary(professional.password_hash)
      refute professional.password_hash == "supersecret12"
      assert is_binary(professional.id)
      assert %DateTime{} = professional.inserted_at
      assert %DateTime{} = professional.updated_at
    end
  end

  describe "register_professional/1 — validation" do
    test "rejects duplicate email with an :email error" do
      base_attrs = %{
        email: "dup@example.com",
        password: "supersecret12",
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
        password: "supersecret12",
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
      password = "supersecret12"

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
end
