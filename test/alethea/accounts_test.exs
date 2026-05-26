defmodule Alethea.AccountsTest do
  use Alethea.DataCase, async: true

  alias Alethea.Accounts

  @valid_attrs %{
    email: "psicologo@example.com",
    password: "contraseña_segura_123",
    full_name: "Dra. Ana García"
  }

  defp create_professional(attrs \\ %{}) do
    {:ok, professional} = Accounts.create_professional(Map.merge(@valid_attrs, attrs))
    professional
  end

  describe "authenticate_professional/2" do
    test "returns professional with valid credentials" do
      professional = create_professional()

      assert {:ok, authenticated} =
               Accounts.authenticate_professional(professional.email, @valid_attrs.password)

      assert authenticated.id == professional.id
    end

    test "returns error with wrong password" do
      professional = create_professional()

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_professional(professional.email, "contraseña_incorrecta_999")
    end

    test "returns error for unknown email without leaking timing" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_professional("noexiste@example.com", "cualquier_contraseña")
    end

    test "returns error when email exists but password is empty string" do
      professional = create_professional()

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_professional(professional.email, "")
    end
  end

  describe "get_professional_by_email/1" do
    test "returns professional for existing email" do
      professional = create_professional()
      found = Accounts.get_professional_by_email(professional.email)
      assert found.id == professional.id
    end

    test "returns nil for unknown email" do
      assert nil == Accounts.get_professional_by_email("noexiste@example.com")
    end
  end
end
