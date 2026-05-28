defmodule Alethea.AccountsTest do
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.Encryption.PatientVault
  alias Alethea.Accounts.EncryptionKey

  @password "password12345"

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "pro-#{System.unique_integer()}@alethea.com",
        full_name: "Pro Test",
        password: @password
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)
    %{professional: professional, kek: kek}
  end

  describe "create_patient/2 y Seguridad" do
    test "cifra el número de WhatsApp y lo hace ilegible en SQL", %{professional: pro, kek: kek} do
      phone = "+56 9 1234 5678"
      # Normalizado debería ser +56912345678

      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "Juan P.",
            "whatsapp_number" => phone,
            "professional_id" => pro.id
          },
          kek
        )

      # 1. Verificar que el número original NO está en la base de datos
      # Repo.query retorna el resultado raw de la DB
      # Necesitamos pasar el UUID en formato binario para Postgrex
      {:ok, binary_id} = Ecto.UUID.dump(patient.id)

      %{rows: [[db_phone]]} =
        Repo.query!("SELECT encrypted_whatsapp_number FROM patients WHERE id = $1", [binary_id])

      assert is_binary(db_phone)
      assert db_phone != phone
      assert db_phone != "+56912345678"

      # 2. Verificar que se puede descifrar usando la KEK y la DEK asociada
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)
      assert {:ok, "+56912345678"} == PatientVault.decrypt(db_phone, dek)
    end

    test "borrado criptográfico: al eliminar la DEK, el dato es irrecuperable", %{
      professional: pro,
      kek: kek
    } do
      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "Juan P.",
            "whatsapp_number" => "+56912345678",
            "professional_id" => pro.id
          },
          kek
        )

      # Obtenemos la DEK
      {:ok, _dek} = Accounts.load_patient_dek(patient, kek)

      # Simulamos el borrado criptográfico eliminando el registro de la llave
      Repo.get_by(EncryptionKey, patient_id: patient.id) |> Repo.delete!()

      # Ahora load_patient_dek debería fallar
      assert {:error, :not_found} == Accounts.load_patient_dek(patient, kek)
    end

    test "unicidad global: no permite registrar el mismo número dos veces (vía hash)", %{
      professional: pro,
      kek: kek
    } do
      phone = "+56912345678"

      {:ok, _patient} =
        Accounts.create_patient(
          %{
            "alias" => "Juan P.",
            "whatsapp_number" => phone,
            "professional_id" => pro.id
          },
          kek
        )

      # Intentamos registrar el mismo número (aunque con formato sucio)
      result =
        Accounts.create_patient(
          %{
            "alias" => "Juan P. Bis",
            "whatsapp_number" => " +56 9-1234 5678 ",
            "professional_id" => pro.id
          },
          kek
        )

      assert {:error, changeset} = result
      assert "has already been taken" in errors_on(changeset).whatsapp_number_hash
    end

    test "normalización E.164: limpia formatos sucios", %{professional: pro, kek: kek} do
      dirty_phone = " (56) 9 1234-5678 "
      # Debería normalizarse a +56912345678

      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "Juan P.",
            "whatsapp_number" => dirty_phone,
            "professional_id" => pro.id
          },
          kek
        )

      {:ok, dek} = Accounts.load_patient_dek(patient, kek)
      assert {:ok, "+56912345678"} == PatientVault.decrypt(patient.encrypted_whatsapp_number, dek)
    end

    test "validación: whatsapp_number es obligatorio y no puede ser nulo o vacío", %{
      professional: pro,
      kek: kek
    } do
      # 1. Caso nil
      assert {:error, changeset} =
               Accounts.create_patient(
                 %{
                   "alias" => "Juan P.",
                   "whatsapp_number" => nil,
                   "professional_id" => pro.id
                 },
                 kek
               )

      assert "can't be blank" in errors_on(changeset).whatsapp_number

      # 2. Caso vacío
      assert {:error, changeset} =
               Accounts.create_patient(
                 %{
                   "alias" => "Juan P.",
                   "whatsapp_number" => "   ",
                   "professional_id" => pro.id
                 },
                 kek
               )

      assert "can't be blank" in errors_on(changeset).whatsapp_number
    end
  end
end
