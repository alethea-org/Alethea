defmodule Alethea.Jobs.TriggerDeliveryLifecycleTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Repo
  alias Alethea.Telegram.{Pacer, Client.Fake}
  alias Alethea.Triggers.Trigger

  import Ecto.Query
  import Alethea.FoundationTestHelper

  @chat_id 987_654_321

  setup do
    {:ok, _} = safe_start_pacer()
    start_supervised!(Fake)
    Fake.reset()
    Application.put_env(:alethea, :telegram_client, Fake)
    Repo.delete_all(Oban.Job)

    patient = bind_patient("lifecycle_hash" |> String.pad_trailing(64, "0"))

    {:ok, _} =
      Alethea.Foundation.Accounts.store_encrypted_telegram_chat_id(
        patient.foundation_patient,
        patient.chat_id
      )

    {:ok, dek} = Clinical.patient_dek(patient.legacy_patient, "test_trigger_lifecycle")
    {:ok, enc_text} = Alethea.Encryption.PatientVault.encrypt("Mensaje proactivo", dek)

    %{patient: patient, enc_text: enc_text}
  end

  defp safe_start_pacer do
    case Process.whereis(Pacer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end

    Pacer.start_link([])
  end

  defp bind_patient(chat_id_hash) do
    legacy_professional = legacy_professional_fixture()
    legacy_patient = legacy_patient_fixture(legacy_professional)

    foundation_patient =
      professional_fixture()
      |> patient_fixture()
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: chat_id_hash,
        legacy_patient_id: legacy_patient.id
      })
      |> Repo.update!()

    %{
      foundation_patient: foundation_patient,
      legacy_patient: legacy_patient,
      chat_id: @chat_id,
      chat_id_hash: chat_id_hash
    }
  end

  describe "TelegramOutboundWorker with deactivated, unapproved, or stale-revision triggers" do
    test "skips delivery when trigger was deactivated before outbound attempt",
         %{patient: patient, enc_text: enc_text} do
      trigger =
        %Trigger{}
        |> Trigger.changeset(%{
          patient_id: patient.legacy_patient.id,
          professional_id: patient.legacy_patient.professional_id,
          instruction: enc_text,
          draft_message: enc_text,
          approved_text: enc_text,
          scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          timezone: "America/Santiago",
          status: "inactive",
          approval_revision: 1
        })
        |> Repo.insert!()

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [delivery_state: "pending"]
      )

      args = %{
        "trigger_id" => trigger.id,
        "message_id" => message.id,
        "lane" => "trigger",
        "approval_revision" => 1
      }

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: args,
                 attempt: 1,
                 priority: 0
               })

      # Skipped delivery: Fake never sent anything
      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end

    test "skips delivery when trigger was unapproved (approved_text is nil)",
         %{patient: patient, enc_text: enc_text} do
      trigger =
        %Trigger{}
        |> Trigger.changeset(%{
          patient_id: patient.legacy_patient.id,
          professional_id: patient.legacy_patient.professional_id,
          instruction: enc_text,
          draft_message: nil,
          approved_text: nil,
          scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          timezone: "America/Santiago",
          status: "active",
          approval_revision: 2
        })
        |> Repo.insert!()

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [delivery_state: "pending"]
      )

      args = %{
        "trigger_id" => trigger.id,
        "message_id" => message.id,
        "lane" => "trigger",
        "approval_revision" => 1
      }

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: args,
                 attempt: 1,
                 priority: 0
               })

      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end

    test "skips delivery when job's approval_revision is older than trigger's approval_revision",
         %{patient: patient, enc_text: enc_text} do
      trigger =
        %Trigger{}
        |> Trigger.changeset(%{
          patient_id: patient.legacy_patient.id,
          professional_id: patient.legacy_patient.professional_id,
          instruction: enc_text,
          draft_message: enc_text,
          approved_text: enc_text,
          scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          timezone: "America/Santiago",
          status: "active",
          approval_revision: 2
        })
        |> Repo.insert!()

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [delivery_state: "pending"]
      )

      # Old job with revision 1 while trigger is now revision 2
      args = %{
        "trigger_id" => trigger.id,
        "message_id" => message.id,
        "lane" => "trigger",
        "approval_revision" => 1
      }

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: args,
                 attempt: 1,
                 priority: 0
               })

      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end

    test "legacy job without approval_revision key delivers when trigger is still at revision 1",
         %{patient: patient, enc_text: enc_text} do
      trigger =
        %Trigger{}
        |> Trigger.changeset(%{
          patient_id: patient.legacy_patient.id,
          professional_id: patient.legacy_patient.professional_id,
          instruction: enc_text,
          draft_message: enc_text,
          approved_text: enc_text,
          scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          timezone: "America/Santiago",
          status: "active",
          approval_revision: 1
        })
        |> Repo.insert!()

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [delivery_state: "pending"]
      )

      # Legacy job without approval_revision in args
      args = %{
        "trigger_id" => trigger.id,
        "message_id" => message.id,
        "lane" => "trigger"
      }

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: args,
                 attempt: 1,
                 priority: 0
               })

      # Legitimate revision 1 legacy send delivered
      assert [%{chat_id: @chat_id, text: "Mensaje proactivo"}] = Fake.sends()
      assert Repo.get!(Message, message.id).delivery_state == "sent"
    end

    test "legacy job without approval_revision key is suppressed when trigger has been edited to revision > 1",
         %{patient: patient, enc_text: enc_text} do
      trigger =
        %Trigger{}
        |> Trigger.changeset(%{
          patient_id: patient.legacy_patient.id,
          professional_id: patient.legacy_patient.professional_id,
          instruction: enc_text,
          draft_message: enc_text,
          approved_text: enc_text,
          scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          timezone: "America/Santiago",
          status: "active",
          approval_revision: 2
        })
        |> Repo.insert!()

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [delivery_state: "pending"]
      )

      # Legacy job without approval_revision in args
      args = %{
        "trigger_id" => trigger.id,
        "message_id" => message.id,
        "lane" => "trigger"
      }

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: args,
                 attempt: 1,
                 priority: 0
               })

      # Suppressed: Fake never sent anything because trigger is now revision 2
      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end
  end
end
