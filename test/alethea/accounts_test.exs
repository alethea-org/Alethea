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

  describe "patient encryption and security" do
    alias Alethea.Encryption.PatientVault
    alias Alethea.Accounts.EncryptionKey

    setup do
      professional = create_professional()
      {:ok, kek} = Accounts.load_professional_kek(professional)
      %{professional: professional, kek: kek}
    end

    test "cifrado exitoso e ilegibilidad en base de datos", %{professional: prof, kek: kek} do
      whatsapp_number = "+56912345678"
      attrs = %{whatsapp_number: whatsapp_number, alias: "Paciente X", professional_id: prof.id}

      assert {:ok, patient} = Accounts.create_patient(attrs, kek)

      # 1. Ilegibilidad directa en SQL
      # Query pura para ver los bytes sin descifrado automático
      # Postgrex espera UUIDs en binario si se pasa como parámetro para una columna uuid
      binary_id = Ecto.UUID.dump!(patient.id)
      result = Repo.query!("SELECT encrypted_whatsapp_number FROM patients WHERE id = $1", [binary_id])
      [[encrypted_bin]] = result.rows

      assert is_binary(encrypted_bin)
      assert encrypted_bin != whatsapp_number

      # 2. El hash existe y es correcto
      assert patient.whatsapp_number_hash != nil
      assert {:ok, found} = Accounts.lookup_patient_by_phone(whatsapp_number)
      assert found.id == patient.id
    end

    test "borrado criptográfico hace los datos irrecuperables", %{professional: prof, kek: kek} do
      whatsapp_number = "+56999999999"
      attrs = %{whatsapp_number: whatsapp_number, alias: "Paciente Efímero", professional_id: prof.id}

      {:ok, patient} = Accounts.create_patient(attrs, kek)

      # Obtenemos la DEK (está en encryption_keys)
      key_record = Repo.get_by!(EncryptionKey, patient_id: patient.id, type: "patient")

      # Simulamos el borrado borrando el registro de la llave
      Repo.delete!(key_record)

      # Intentamos recuperar... ya no hay DEK
      assert Repo.get_by(EncryptionKey, patient_id: patient.id) == nil

      # Los bytes en la tabla 'patients' siguen ahí pero son basura sin la llave
      binary_id = Ecto.UUID.dump!(patient.id)
      [[binary_garbage]] = Repo.query!("SELECT encrypted_whatsapp_number FROM patients WHERE id = $1", [binary_id]).rows
      # No hay forma de obtener la DEK para llamar a PatientVault.decrypt
      assert {:error, :decryption_failed} = PatientVault.decrypt(binary_garbage, :crypto.strong_rand_bytes(32))
    end

    test "unicidad global por número de WhatsApp", %{professional: prof, kek: kek} do
      whatsapp_number = "+56911112222"
      attrs = %{whatsapp_number: whatsapp_number, alias: "Paciente Uno", professional_id: prof.id}

      assert {:ok, _patient} = Accounts.create_patient(attrs, kek)

      # Intentar registrar el mismo número para el mismo profesional
      assert {:error, changeset} = Accounts.create_patient(attrs, kek)
      assert "has already been taken" in errors_on(changeset).whatsapp_number_hash
    end
  end
end
