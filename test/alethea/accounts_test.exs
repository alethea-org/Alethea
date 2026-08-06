defmodule Alethea.AccountsTest do
  use Alethea.DataCase, async: true

  alias Alethea.Accounts
  alias Alethea.Clinical
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

  describe "create_patient/2 (alias-only identity)" do
    test "registra un paciente usando solo el alias", %{professional: pro, kek: kek} do
      assert {:ok, patient} =
               Accounts.create_patient(
                 %{
                   "alias" => "Juan P.",
                   "professional_id" => pro.id
                 },
                 kek
               )

      assert patient.alias == "Juan P."
      assert patient.professional_id == pro.id
    end

    test "dos pacientes del mismo profesional pueden compartir el alias", %{
      professional: pro,
      kek: kek
    } do
      assert {:ok, _first} =
               Accounts.create_patient(%{"alias" => "Ana", "professional_id" => pro.id}, kek)

      # No hay unicidad sobre el alias legacy: la identidad única vive en
      # el `telegram_chat_id_hash` de foundation, no acá.
      assert {:ok, second} =
               Accounts.create_patient(%{"alias" => "Ana", "professional_id" => pro.id}, kek)

      assert second.alias == "Ana"
    end

    test "provisiona una EncryptionKey tipo \"patient\" y enlaza encryption_key_id", %{
      professional: pro,
      kek: kek
    } do
      {:ok, patient} =
        Accounts.create_patient(
          %{"alias" => "Con Llave", "professional_id" => pro.id},
          kek
        )

      # La DEK del paciente quedó provisionada y enlazada.
      assert is_binary(patient.encryption_key_id)

      key = Accounts.get_encryption_key_for_patient(patient.id)
      assert %EncryptionKey{} = key
      assert key.type == "patient"
      assert key.patient_id == patient.id
      assert key.id == patient.encryption_key_id
    end

    test "sin alias devuelve {:error, changeset}", %{professional: pro, kek: kek} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.create_patient(
                 %{"professional_id" => pro.id},
                 kek
               )

      assert "can't be blank" in errors_on(changeset).alias
    end

    test "regresión de cifrado: un mensaje se cifra al escribir y descifra al leer vía la DEK provisionada",
         %{professional: pro, kek: kek} do
      {:ok, patient} =
        Accounts.create_patient(
          %{"alias" => "Cifrado", "professional_id" => pro.id},
          kek
        )

      # Cargar la DEK provisionada por create_patient (KEK → DEK).
      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      plaintext = "Hoy me siento tranquilo y esperanzado."

      {:ok, message} =
        Clinical.save_message(patient, plaintext, dek, "inbound", "spontaneous")

      # El contenido en reposo NO es el texto plano.
      assert message.encrypted_content != plaintext
      refute message.encrypted_content == nil

      # Round-trip: descifra de vuelta al original con la misma DEK.
      assert {:ok, plaintext} == Clinical.decrypt_message_content(message, dek)
    end

    test "auditoría: registra un log cuando se crea un paciente", %{professional: pro, kek: kek} do
      {:ok, patient} =
        Accounts.create_patient(
          %{"alias" => "Auditable", "professional_id" => pro.id},
          kek
        )

      log =
        Repo.get_by(Alethea.Accounts.AuditLog, action: "CREATE_PATIENT", resource_id: patient.id)

      assert log
      assert log.professional_id == pro.id
      assert log.details["alias"] == "Auditable"
    end
  end
end
