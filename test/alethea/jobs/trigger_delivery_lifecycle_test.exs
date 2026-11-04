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

    test "concurrent instruction edit holding trigger lock serializes outbound delivery and suppresses send on approval removal" do
      chat_id_hash = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

      {p, tr, msg} =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          patient = bind_patient(chat_id_hash)

          {:ok, _} =
            Alethea.Foundation.Accounts.store_encrypted_telegram_chat_id(
              patient.foundation_patient,
              patient.chat_id
            )

          {:ok, dek} = Clinical.patient_dek(patient.legacy_patient, "test_race")
          {:ok, enc} = Alethea.Encryption.PatientVault.encrypt("Mensaje proactivo", dek)
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          trigger =
            Repo.insert!(%Trigger{
              patient_id: patient.legacy_patient.id,
              professional_id: patient.legacy_patient.professional_id,
              instruction: enc,
              draft_message: enc,
              approved_text: enc,
              scheduled_at: now,
              timezone: "America/Santiago",
              status: "active",
              approval_revision: 1
            })

          message =
            Repo.insert!(%Message{
              patient_id: patient.legacy_patient.id,
              direction: "outbound",
              behavior_type: "spontaneous",
              encrypted_content: enc,
              delivery_state: "pending",
              trigger_id: trigger.id,
              timestamp: now
            })

          {patient, trigger, message}
        end)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          l_pid = Ecto.UUID.dump!(p.legacy_patient.professional_id)
          f_pid = Ecto.UUID.dump!(p.foundation_patient.professional_id)
          Repo.query!("DELETE FROM messages WHERE id = $1", [Ecto.UUID.dump!(msg.id)])
          Repo.query!("DELETE FROM triggers WHERE id = $1", [Ecto.UUID.dump!(tr.id)])
          Repo.query!("DELETE FROM audit_logs WHERE professional_id = $1", [l_pid])

          Repo.query!("DELETE FROM foundation_patients WHERE id = $1", [
            Ecto.UUID.dump!(p.foundation_patient.id)
          ])

          Repo.query!("DELETE FROM patients WHERE id = $1", [Ecto.UUID.dump!(p.legacy_patient.id)])

          Repo.query!("DELETE FROM encryption_keys WHERE professional_id = $1", [l_pid])
          Repo.query!("DELETE FROM foundation_professionals WHERE id = $1", [f_pid])
          Repo.query!("DELETE FROM professionals WHERE id = $1", [l_pid])
        end)
      end)

      task_sup = start_supervised!(Task.Supervisor)
      parent = self()

      holder =
        Task.Supervisor.async_nolink(task_sup, fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            h_pid = hd(hd(Repo.query!("SELECT pg_backend_pid()").rows))

            Repo.transaction(fn ->
              Repo.query!("SELECT * FROM triggers WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(tr.id)
              ])

              send(parent, {:holder_locked, h_pid})

              receive do
                :commit_edit ->
                  Repo.query!(
                    "UPDATE triggers SET approved_text = NULL, draft_message = NULL, approval_revision = 2 WHERE id = $1",
                    [Ecto.UUID.dump!(tr.id)]
                  )
              end
            end)

            send(parent, :holder_done)
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      assert_receive {:holder_locked, h_pid}, 5_000

      worker =
        Task.Supervisor.async_nolink(task_sup, fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            w_pid = hd(hd(Repo.query!("SELECT pg_backend_pid()").rows))
            send(parent, {:worker_started, w_pid})

            TelegramOutboundWorker.perform(%Oban.Job{
              args: %{
                "trigger_id" => tr.id,
                "message_id" => msg.id,
                "lane" => "trigger",
                "approval_revision" => 1
              },
              attempt: 1,
              priority: 0
            })
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      assert_receive {:worker_started, w_pid}, 5_000
      assert :ok = await_trigger_lock_waiter(w_pid, h_pid)

      send(holder.pid, :commit_edit)
      assert_receive :holder_done, 5_000
      assert :ok = Task.await(worker, 5_000)

      assert Fake.sends() == []
      assert Repo.get!(Message, msg.id).delivery_state == "pending"
      assert Repo.get!(Trigger, tr.id).approved_text == nil
    end

    test "skips delivery when trigger is paused_by_crisis (Issue #443)", %{
      patient: patient,
      enc_text: enc_text
    } do
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
          status: "paused_by_crisis",
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

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: %{
                   "trigger_id" => trigger.id,
                   "message_id" => message.id,
                   "lane" => "trigger",
                   "approval_revision" => 1
                 },
                 attempt: 1,
                 priority: 0
               })

      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end

    test "skips delivery when patient is under urgent intervention (Issue #443)", %{
      patient: patient,
      enc_text: enc_text
    } do
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

      patient.legacy_patient
      |> Ecto.Changeset.change(%{urgent_intervention: true})
      |> Repo.update!()

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: %{
                   "trigger_id" => trigger.id,
                   "message_id" => message.id,
                   "lane" => "trigger",
                   "approval_revision" => 1
                 },
                 attempt: 1,
                 priority: 0
               })

      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end

    test "skips delivery when trigger is paused_by_delivery_failures (#445)", %{
      patient: patient,
      enc_text: enc_text
    } do
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
          status: "paused_by_delivery_failures",
          approval_revision: 1,
          consecutive_delivery_failures: 3
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

      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: %{
                   "trigger_id" => trigger.id,
                   "message_id" => message.id,
                   "lane" => "trigger",
                   "approval_revision" => 1
                 },
                 attempt: 1,
                 priority: 0
               })

      assert Fake.sends() == []
      assert Repo.get!(Message, message.id).delivery_state == "pending"
    end
  end

  describe "Trigger delivery failures and pause lifecycle (#445)" do
    alias Alethea.Accounts.AuditLog
    alias Alethea.Foundation.Accounts.OutboundDeadLetter
    alias Alethea.Triggers.{Trigger, TriggerFiring}

    test "exhausted delivery failure dead-letters, marks firing as not_delivered, and increments failure count (S1-S3)",
         %{patient: patient, enc_text: enc_text} do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "ops:alerts")

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
          schedule_type: "daily",
          time: ~T[10:00:00],
          consecutive_delivery_failures: 0
        })
        |> Repo.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: now
        })
        |> Ecto.Changeset.put_change(:delivery_state, "pending")
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      firing =
        %TriggerFiring{}
        |> TriggerFiring.changeset(%{
          trigger_id: trigger.id,
          message_id: message.id,
          status: "fired",
          fired_at: now,
          scheduled_at: trigger.scheduled_at
        })
        |> Repo.insert!()

      Fake.queue_responses([{:error, {:rate_limited, 2}}])

      args = %{
        "trigger_id" => trigger.id,
        "message_id" => message.id,
        "lane" => "trigger",
        "approval_revision" => 1,
        "_attempt" => 5
      }

      # Run at attempt 5 (exhaustion)
      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: args,
                 attempt: 5,
                 priority: 0
               })

      # Dead-letter row written to foundation_outbound_dead_letters
      assert [dead_letter] = Repo.all(OutboundDeadLetter)
      assert dead_letter.attempts == 5
      assert dead_letter.outcome == "failed"

      # PubSub event broadcast on ops:alerts
      assert_receive {:outbound_dead_letter, %{attempts: 5}}, 1_000

      # Message marked failed
      assert Repo.get!(Message, message.id).delivery_state == "failed"

      # Trigger firing marked not_delivered
      assert Repo.get!(TriggerFiring, firing.id).status == "not_delivered"

      # Trigger failure count incremented to 1, still active
      reloaded_trigger = Repo.get!(Trigger, trigger.id)
      assert reloaded_trigger.consecutive_delivery_failures == 1
      assert reloaded_trigger.status == "active"
    end

    test "3 consecutive delivery failures pause the trigger, cancel jobs, and write audit log (S3)",
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
          schedule_type: "daily",
          time: ~T[10:00:00],
          consecutive_delivery_failures: 2
        })
        |> Repo.insert!()

      # Schedule a future job that should be cancelled when paused
      future_time = DateTime.utc_now() |> DateTime.add(3600, :second)

      %{"trigger_id" => trigger.id}
      |> AletheaJobs.ActiveTriggerWorker.new(scheduled_at: future_time)
      |> Oban.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: now
        })
        |> Ecto.Changeset.put_change(:delivery_state, "pending")
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      firing =
        %TriggerFiring{}
        |> TriggerFiring.changeset(%{
          trigger_id: trigger.id,
          message_id: message.id,
          status: "fired",
          fired_at: now,
          scheduled_at: trigger.scheduled_at
        })
        |> Repo.insert!()

      Fake.queue_responses([{:error, {:rate_limited, 2}}])

      # Run 3rd failure attempt 5
      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: %{
                   "trigger_id" => trigger.id,
                   "message_id" => message.id,
                   "lane" => "trigger",
                   "approval_revision" => 1,
                   "_attempt" => 5
                 },
                 attempt: 5,
                 priority: 0
               })

      # Trigger is now paused_by_delivery_failures
      reloaded_trigger = Repo.get!(Trigger, trigger.id)
      assert reloaded_trigger.consecutive_delivery_failures == 3
      assert reloaded_trigger.status == "paused_by_delivery_failures"

      # Firing is not_delivered
      assert Repo.get!(TriggerFiring, firing.id).status == "not_delivered"

      # Scheduled Oban jobs were cancelled
      scheduled_jobs =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "AletheaJobs.ActiveTriggerWorker" and
                fragment("?->>'trigger_id' = ?", j.args, ^trigger.id) and
                j.state in ["scheduled", "available", "retryable"]
        )

      assert scheduled_jobs == []

      # Audit log recorded
      audit_logs =
        Repo.all(
          from a in AuditLog,
            where:
              a.resource_id == ^trigger.id and
                a.action == "trigger_paused_by_delivery_failures"
        )

      assert length(audit_logs) == 1
    end

    test "successful delivery resets consecutive_delivery_failures counter (S4)",
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
          schedule_type: "daily",
          time: ~T[10:00:00],
          consecutive_delivery_failures: 2
        })
        |> Repo.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.legacy_patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc_text,
          timestamp: now
        })
        |> Ecto.Changeset.put_change(:delivery_state, "pending")
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Repo.insert!()

      %TriggerFiring{}
      |> TriggerFiring.changeset(%{
        trigger_id: trigger.id,
        message_id: message.id,
        status: "fired",
        fired_at: now,
        scheduled_at: trigger.scheduled_at
      })
      |> Repo.insert!()

      # Fake returns success by default
      assert :ok =
               TelegramOutboundWorker.perform(%Oban.Job{
                 args: %{
                   "trigger_id" => trigger.id,
                   "message_id" => message.id,
                   "lane" => "trigger",
                   "approval_revision" => 1
                 },
                 attempt: 1,
                 priority: 0
               })

      assert Repo.get!(Message, message.id).delivery_state == "sent"

      # Counter reset to 0
      reloaded_trigger = Repo.get!(Trigger, trigger.id)
      assert reloaded_trigger.consecutive_delivery_failures == 0
      assert reloaded_trigger.status == "active"
    end
  end

  defp await_trigger_lock_waiter(worker_pid, holder_pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    [[pids]] =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT pg_blocking_pids($1)", [worker_pid]).rows
      end)

    cond do
      holder_pid in pids ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Worker was not serialized behind trigger lock holder")

      true ->
        receive after: (10 -> await_trigger_lock_waiter(worker_pid, holder_pid, deadline))
    end
  end
end
