defmodule Alethea.Jobs.TelegramChatIdEncryptionTest do
  @moduledoc """
  Integration tests for Telegram chat_id encryption during onboarding and inbound messages (S2, S3, S5).
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import ExUnit.CaptureLog

  alias Alethea.Accounts, as: LegacyAccounts
  alias Alethea.Clinical.Message
  alias Alethea.Foundation.Accounts
  alias Alethea.Foundation.Accounts.{Patient, PatientAuthCode}
  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOnboardingWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 987_654_321
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

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

  describe "S2: onboarding stores encrypted chat_id" do
    test "successful onboarding stores encrypted chat_id and decrypts to integer", %{
      patient: patient
    } do
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      reloaded_patient = Repo.get!(Patient, patient.id)
      assert reloaded_patient.telegram_chat_id_hash == @chat_id_hash
      assert is_binary(reloaded_patient.encrypted_telegram_chat_id)
      refute reloaded_patient.encrypted_telegram_chat_id =~ to_string(@chat_id)

      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(reloaded_patient)
    end

    test "onboarding failure when patient has no legacy link does not bind or consume", %{
      foundation_pro: foundation_pro
    } do
      {:ok, unlinked_patient} =
        Accounts.create_patient(foundation_pro, %{
          alias: "unlinked-patient-#{unique_int()}"
        })

      {:ok, auth_code} =
        PatientAuthCode.create_patient_auth_code(unlinked_patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert {:error, _} = TelegramOnboardingWorker.perform(job)

      reloaded_patient = Repo.get!(Patient, unlinked_patient.id)
      assert reloaded_patient.telegram_chat_id_hash == nil
      assert reloaded_patient.encrypted_telegram_chat_id == nil

      reloaded_code = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded_code.used_at == nil

      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "onboarding failure when patient DEK is missing does not bind or consume", %{
      patient: patient,
      legacy_patient: legacy_patient
    } do
      key_record = Repo.get!(LegacyAccounts.EncryptionKey, legacy_patient.encryption_key_id)
      Repo.delete!(key_record)

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert {:error, :missing_encryption_key} = TelegramOnboardingWorker.perform(job)

      reloaded_patient = Repo.get!(Patient, patient.id)
      assert reloaded_patient.telegram_chat_id_hash == nil
      assert reloaded_patient.encrypted_telegram_chat_id == nil

      reloaded_code = Repo.get!(PatientAuthCode, auth_code.id)
      assert reloaded_code.used_at == nil

      refute_enqueued(worker: TelegramOutboundWorker)
    end
  end

  describe "S3: inbound message backfill and refresh" do
    test "existing patient without encrypted chat_id gets it backfilled on next inbound", %{
      patient: patient
    } do
      # Bind hash only (simulating pre-existing patient)
      patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      assert Repo.get!(Patient, patient.id).encrypted_telegram_chat_id == nil

      args = build_inbound_args("Hola, este es un mensaje", @chat_id, 101, 101)

      # Inbound execution
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      reloaded = Repo.get!(Patient, patient.id)
      assert is_binary(reloaded.encrypted_telegram_chat_id)
      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(reloaded)
    end

    test "refresh occurs on empty-text inbound (e.g. sticker/photo) without persisting Message",
         %{patient: patient} do
      # Pre-bind hash with nil ciphertext
      patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      assert Repo.get!(Patient, patient.id).encrypted_telegram_chat_id == nil

      args = build_inbound_args(nil, @chat_id, 102, 102)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      # Encrypted chat id was backfilled/refreshed
      reloaded = Repo.get!(Patient, patient.id)
      assert is_binary(reloaded.encrypted_telegram_chat_id)
      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(reloaded)

      # But message is dropped (no Message row, no outbound reply)
      assert Repo.aggregate(Message, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "empty-text inbound from unlinked foundation patient is dropped as a no-op (:ok)",
         %{foundation_pro: foundation_pro} do
      {:ok, unlinked_patient} =
        Accounts.create_patient(foundation_pro, %{
          alias: "unlinked-empty-#{unique_int()}"
        })

      # Bind hash on foundation patient, but legacy_patient_id remains nil
      unlinked_patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      args = build_inbound_args(nil, @chat_id, 107, 107)

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      assert Repo.aggregate(Message, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "subsequent inbound updates/refreshes ciphertext", %{patient: patient} do
      # Bind with an initial encryption
      {:ok, _} = Accounts.store_encrypted_telegram_chat_id(patient, @chat_id)

      patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      first_ciphertext = Repo.get!(Patient, patient.id).encrypted_telegram_chat_id

      args = build_inbound_args("Mensaje 2", @chat_id, 103, 103)
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

      second_ciphertext = Repo.get!(Patient, patient.id).encrypted_telegram_chat_id
      assert is_binary(second_ciphertext)
      # Fresh IV produces distinct ciphertext
      refute second_ciphertext == first_ciphertext
      assert {:ok, @chat_id} = Accounts.decrypted_telegram_chat_id(patient)
    end

    test "inbound message with encryption failure raises retryable failure and does not pretend success",
         %{patient: patient, legacy_patient: legacy_patient} do
      patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      # Cryptographic deletion: delete the EncryptionKey row
      key_record = Repo.get!(Alethea.Accounts.EncryptionKey, legacy_patient.encryption_key_id)
      Repo.delete!(key_record)

      args = build_inbound_args("Mensaje sin clave", @chat_id, 105, 105)

      assert_raise RuntimeError, ~r/failed to encrypt\/store chat_id/, fn ->
        TelegramMessageWorker.perform(%Oban.Job{args: args})
      end

      # No Message persisted, no outbound reply enqueued
      assert Repo.aggregate(Message, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)
    end
  end

  describe "S5: logs never contain plaintext chat_id" do
    test "onboarding success and failure never leak plaintext chat_id", %{patient: patient} do
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      log =
        capture_log(fn ->
          TelegramOnboardingWorker.perform(job)
        end)

      refute log =~ to_string(@chat_id)
    end

    test "inbound processing never leaks plaintext chat_id", %{patient: patient} do
      patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      args = build_inbound_args("Mensaje para logging test", @chat_id, 104, 104)

      log =
        capture_log(fn ->
          TelegramMessageWorker.perform(%Oban.Job{args: args})
        end)

      refute log =~ to_string(@chat_id)
    end

    test "inbound encryption failure log never contains plaintext chat_id",
         %{patient: patient, legacy_patient: legacy_patient} do
      patient
      |> Ecto.Changeset.change(%{telegram_chat_id_hash: @chat_id_hash})
      |> Repo.update!()

      key_record = Repo.get!(Alethea.Accounts.EncryptionKey, legacy_patient.encryption_key_id)
      Repo.delete!(key_record)

      args = build_inbound_args("Mensaje para log de falla", @chat_id, 106, 106)

      log =
        capture_log(fn ->
          catch_error(TelegramMessageWorker.perform(%Oban.Job{args: args}))
        end)

      refute log =~ to_string(@chat_id)
      assert log =~ "failed to encrypt/store chat_id"
    end
  end

  defp build_inbound_args(text, chat_id, message_id, update_id) do
    %{
      "telegram_update_id" => update_id,
      "message" => %{
        "message_id" => message_id,
        "date" => 1_700_000_000,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => chat_id, "is_bot" => false, "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp unique_int, do: System.unique_integer([:positive])
end
