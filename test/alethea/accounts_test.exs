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

  describe "clinical-record-scoped encryption key (D1, sdd/clinical-record-retention #197)" do
    test "load_clinical_record_dek/2 returns {:error, :not_found} before any key exists", %{
      professional: pro,
      kek: kek
    } do
      {:ok, patient} =
        Accounts.create_patient(%{"alias" => "CR Sin Llave", "professional_id" => pro.id}, kek)

      assert {:error, :not_found} = Accounts.load_clinical_record_dek(patient, kek)
    end

    test "ensure_clinical_record_dek/2 lazily creates a 32-byte key on first call and returns the SAME key on a repeat call",
         %{professional: pro, kek: kek} do
      {:ok, patient} =
        Accounts.create_patient(%{"alias" => "CR Lazy", "professional_id" => pro.id}, kek)

      assert Repo.aggregate(
               from(k in EncryptionKey,
                 where: k.patient_id == ^patient.id and k.type == "patient_clinical_record"
               ),
               :count
             ) == 0

      assert {:ok, first_dek} = Accounts.ensure_clinical_record_dek(patient, kek)
      assert is_binary(first_dek)
      assert byte_size(first_dek) == 32

      assert {:ok, second_dek} = Accounts.ensure_clinical_record_dek(patient, kek)
      assert second_dek == first_dek

      assert Repo.aggregate(
               from(k in EncryptionKey,
                 where: k.patient_id == ^patient.id and k.type == "patient_clinical_record"
               ),
               :count
             ) == 1
    end

    test "ensure_clinical_record_dek/2 provisions a DIFFERENT key from the patient's journaling DEK (triangulation)",
         %{professional: pro, kek: kek} do
      {:ok, patient} =
        Accounts.create_patient(%{"alias" => "CR Distinta", "professional_id" => pro.id}, kek)

      {:ok, patient_dek} = Accounts.load_patient_dek(patient, kek)
      {:ok, clinical_record_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      refute clinical_record_dek == patient_dek
      assert {:ok, ^clinical_record_dek} = Accounts.load_clinical_record_dek(patient, kek)
    end

    test "destroy_clinical_record_dek/1 deletes the row and returns {:ok, :destroyed}", %{
      professional: pro,
      kek: kek
    } do
      {:ok, patient} =
        Accounts.create_patient(%{"alias" => "CR Destruir", "professional_id" => pro.id}, kek)

      {:ok, _dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      assert {:ok, :destroyed} = Accounts.destroy_clinical_record_dek(patient.id)
      assert {:error, :not_found} = Accounts.load_clinical_record_dek(patient, kek)
    end

    test "destroy_clinical_record_dek/1 is idempotent: returns {:ok, :absent} when no CR key exists (triangulation)",
         %{professional: pro, kek: kek} do
      {:ok, patient} =
        Accounts.create_patient(%{"alias" => "CR Ausente", "professional_id" => pro.id}, kek)

      assert {:ok, :absent} = Accounts.destroy_clinical_record_dek(patient.id)
    end
  end

  describe "D1/BR3 boundary — mandatory: terminal CR-key erasure never touches the shared patient DEK" do
    test "destroys only the CR key row: \"patient\" row survives, Clinical.patient_dek/1 still decrypts journaling",
         %{professional: pro, kek: kek} do
      {:ok, patient} =
        Accounts.create_patient(%{"alias" => "Frontera D1", "professional_id" => pro.id}, kek)

      {:ok, patient_dek_before} = Accounts.load_patient_dek(patient, kek)
      {:ok, _cr_dek} = Accounts.ensure_clinical_record_dek(patient, kek)

      plaintext = "Registro de journaling que debe sobrevivir a la erasure de ClinicalRecord"

      {:ok, message} =
        Clinical.save_message(patient, plaintext, patient_dek_before, "inbound", "spontaneous")

      keys_before =
        EncryptionKey |> where([k], k.patient_id == ^patient.id) |> Repo.all()

      assert length(keys_before) == 2
      assert Enum.any?(keys_before, &(&1.type == "patient"))
      assert Enum.any?(keys_before, &(&1.type == "patient_clinical_record"))

      # Terminal erasure — the exact operation D1/BR3 forbids from ever
      # touching the shared "patient" row.
      assert {:ok, :destroyed} = Accounts.destroy_clinical_record_dek(patient.id)

      keys_after =
        EncryptionKey |> where([k], k.patient_id == ^patient.id) |> Repo.all()

      assert length(keys_after) == 1
      assert hd(keys_after).type == "patient"

      # The shared patient DEK still decrypts via the untouched code path —
      # `Alethea.Clinical.patient_dek/1` (must-not-touch table, design.md).
      assert {:ok, ^patient_dek_before} = Clinical.patient_dek(patient)
      assert {:ok, ^plaintext} = Clinical.decrypt_message_content(message, patient_dek_before)
    end
  end
end
