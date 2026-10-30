defmodule Alethea.Foundation.Accounts.EncryptedTelegramChatIdTest do
  @moduledoc """
  Tests for encrypted Telegram chat_id storage and retrieval in Foundation Accounts (S1, S4, S5).
  """

  use Alethea.DataCase, async: false

  alias Alethea.Accounts, as: LegacyAccounts
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Foundation.Accounts
  alias Alethea.Foundation.Accounts.Patient
  alias Alethea.Repo

  @chat_id 987_654_321

  setup do
    {:ok, legacy_pro} =
      LegacyAccounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Pro Test #{unique_int()}"
      })

    {:ok, kek} = LegacyAccounts.load_professional_kek(legacy_pro)

    {:ok, legacy_patient} =
      LegacyAccounts.create_patient(
        %{
          "alias" => "legacy-alias-#{unique_int()}",
          "professional_id" => legacy_pro.id
        },
        kek
      )

    {:ok, foundation_pro} =
      Accounts.find_or_provision_foundation_professional(legacy_pro)

    {:ok, patient} =
      Accounts.create_patient(foundation_pro, %{
        alias: "patient-alias-#{unique_int()}",
        legacy_patient_id: legacy_patient.id
      })

    %{
      legacy_pro: legacy_pro,
      legacy_patient: legacy_patient,
      foundation_pro: foundation_pro,
      patient: patient
    }
  end

  describe "Patient schema and changeset" do
    test "encrypted_telegram_chat_id is not cast through generic changeset", %{patient: patient} do
      changeset =
        Patient.changeset(patient, %{
          encrypted_telegram_chat_id: "raw-ciphertext-attempt"
        })

      refute Map.has_key?(changeset.changes, :encrypted_telegram_chat_id)
      assert Ecto.Changeset.get_field(changeset, :encrypted_telegram_chat_id) == nil
    end
  end

  describe "store_encrypted_telegram_chat_id/2 and decrypted_telegram_chat_id/1" do
    test "stores encrypted chat_id (not plaintext) and retrieves decrypted integer", %{
      patient: patient
    } do
      assert {:ok, updated_patient} =
               Accounts.store_encrypted_telegram_chat_id(patient, @chat_id)

      assert is_binary(updated_patient.encrypted_telegram_chat_id)
      assert byte_size(updated_patient.encrypted_telegram_chat_id) > 0
      refute updated_patient.encrypted_telegram_chat_id =~ to_string(@chat_id)

      # Persisted row also matches
      reloaded = Repo.get!(Patient, patient.id)
      assert reloaded.encrypted_telegram_chat_id == updated_patient.encrypted_telegram_chat_id

      # Decryption returns tagged integer
      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(patient)
    end

    test "supports negative chat_id (supergroups/channels) and string inputs", %{
      patient: patient
    } do
      channel_chat_id = -100_123_456_789

      assert {:ok, _} =
               Accounts.store_encrypted_telegram_chat_id(patient, channel_chat_id)

      assert {:ok, ^channel_chat_id} = Accounts.decrypted_telegram_chat_id(patient)

      # String input representing valid integer
      assert {:ok, _} =
               Accounts.store_encrypted_telegram_chat_id(patient, "555123456")

      assert {:ok, 555_123_456} = Accounts.decrypted_telegram_chat_id(patient)
    end

    test "rejects invalid chat_id input", %{patient: patient} do
      assert {:error, :invalid_chat_id} =
               Accounts.store_encrypted_telegram_chat_id(patient, "not-a-number")

      assert {:error, :invalid_chat_id} =
               Accounts.store_encrypted_telegram_chat_id(patient, nil)
    end

    test "returns {:error, :missing_ciphertext} when no chat_id was stored", %{patient: patient} do
      assert {:error, :missing_ciphertext} = Accounts.decrypted_telegram_chat_id(patient)
    end

    test "returns {:error, :not_linked} when patient has no legacy_patient_id", %{
      foundation_pro: foundation_pro
    } do
      {:ok, unlinked_patient} =
        Accounts.create_patient(foundation_pro, %{
          alias: "unlinked-#{unique_int()}"
        })

      assert {:error, :patient_not_linked} =
               Accounts.store_encrypted_telegram_chat_id(unlinked_patient, @chat_id)

      assert {:error, :not_linked} =
               Accounts.decrypted_telegram_chat_id(unlinked_patient)
    end
  end

  describe "S4: cryptographic deletion and tamper resistance" do
    test "destroying patient's key makes chat_id unrecoverable even with stale patient struct", %{
      patient: patient,
      legacy_patient: legacy_patient
    } do
      assert {:ok, stale_patient} =
               Accounts.store_encrypted_telegram_chat_id(patient, @chat_id)

      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(stale_patient)

      # Cryptographic deletion: delete the sandbox EncryptionKey row
      key_record = Repo.get!(EncryptionKey, legacy_patient.encryption_key_id)
      Repo.delete!(key_record)

      # Stale struct in memory cannot be used to decrypt; retrieval fails safely
      assert {:error, :missing_encryption_key} =
               Accounts.decrypted_telegram_chat_id(stale_patient)
    end

    test "tampered ciphertext fails decryption safely", %{patient: patient} do
      assert {:ok, _} = Accounts.store_encrypted_telegram_chat_id(patient, @chat_id)

      # Tamper with the persisted ciphertext in DB
      corrupted_bytes = :crypto.strong_rand_bytes(48)

      patient
      |> Ecto.Changeset.change(%{})
      |> Ecto.Changeset.put_change(:encrypted_telegram_chat_id, corrupted_bytes)
      |> Repo.update!()

      assert {:error, :decryption_failed} = Accounts.decrypted_telegram_chat_id(patient)
    end

    test "retrieval fetches fresh persisted ciphertext, ignoring caller-supplied struct alterations",
         %{patient: patient} do
      assert {:ok, updated_patient} =
               Accounts.store_encrypted_telegram_chat_id(patient, @chat_id)

      # Tamper with the in-memory struct only
      spoofed_patient = %{
        updated_patient
        | encrypted_telegram_chat_id: :crypto.strong_rand_bytes(48)
      }

      # Because retrieval queries fresh DB state, it still succeeds and returns the true chat_id
      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(spoofed_patient)
    end

    test "ciphertext encrypted with another patient's DEK fails decryption safely", %{
      patient: patient,
      foundation_pro: foundation_pro,
      legacy_pro: legacy_pro
    } do
      {:ok, kek} = LegacyAccounts.load_professional_kek(legacy_pro)

      {:ok, other_legacy_patient} =
        LegacyAccounts.create_patient(
          %{"alias" => "other-legacy-#{unique_int()}", "professional_id" => legacy_pro.id},
          kek
        )

      {:ok, other_patient} =
        Accounts.create_patient(foundation_pro, %{
          alias: "other-patient-#{unique_int()}",
          legacy_patient_id: other_legacy_patient.id
        })

      # Store chat_id under other_patient (uses other_patient's DEK)
      {:ok, other_stored} =
        Accounts.store_encrypted_telegram_chat_id(other_patient, @chat_id)

      # Tamper patient's DB row to have other_patient's ciphertext
      patient
      |> Ecto.Changeset.change(%{})
      |> Ecto.Changeset.put_change(
        :encrypted_telegram_chat_id,
        other_stored.encrypted_telegram_chat_id
      )
      |> Repo.update!()

      # Decrypting patient's row with patient's own DEK must fail with :decryption_failed
      assert {:error, :decryption_failed} = Accounts.decrypted_telegram_chat_id(patient)
    end
  end

  defp unique_int, do: System.unique_integer([:positive])
end
