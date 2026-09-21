defmodule Alethea.ClinicalTest do
  # async: false — the atomicity test (4.4) issues a raw `ALTER TABLE
  # oban_jobs ADD CONSTRAINT ...` DDL statement scoped to one
  # `professional_id`, mirroring the exact technique used by
  # `Alethea.ClinicalRecordTest`'s "create_target_behavior/3 —
  # atomicity" describe block (that file is `async: false` for the
  # same reason: the DDL takes a Postgres lock on the table for the
  # duration of the sandboxed transaction).
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Ecto.Query

  alias Alethea.{Accounts, Clinical}
  alias Alethea.Clinical.Message
  alias AletheaJobs.{ClinicalRecordOutboxWorker, SafeReason}

  describe "latest_weekly_summary/1" do
    setup do
      {:ok, professional} =
        Accounts.create_professional(%{
          email: "test-#{System.unique_integer([:positive])}@alethea.com",
          password: "password1234",
          full_name: "Dra. Test"
        })

      {:ok, patient} =
        Accounts.create_patient(%{
          alias: "Paciente Semanal",
          professional_id: professional.id
        })

      %{patient: patient}
    end

    test "returns nil when the patient has no weekly summary", %{patient: patient} do
      insert_summary(patient, "session", days_ago: 1)

      refute Clinical.latest_weekly_summary(patient.id)
    end

    test "returns the weekly summary even when its period started over a week ago", %{
      patient: patient
    } do
      insert_summary(patient, "session", days_ago: 2)
      weekly = insert_summary(patient, "weekly", days_ago: 9)

      assert %{id: id, type: "weekly"} = Clinical.latest_weekly_summary(patient.id)
      assert id == weekly.id
    end

    test "returns the most recent weekly summary", %{patient: patient} do
      insert_summary(patient, "weekly", days_ago: 21)
      newest = insert_summary(patient, "weekly", days_ago: 7)

      assert %{id: id} = Clinical.latest_weekly_summary(patient.id)
      assert id == newest.id
    end

    test "ignores weekly summaries belonging to another patient", %{patient: patient} do
      {:ok, other_professional} =
        Accounts.create_professional(%{
          email: "other-#{System.unique_integer([:positive])}@alethea.com",
          password: "password1234",
          full_name: "Dr. Otro"
        })

      {:ok, other_patient} =
        Accounts.create_patient(%{
          alias: "Otro Paciente",
          professional_id: other_professional.id
        })

      insert_summary(other_patient, "weekly", days_ago: 1)

      refute Clinical.latest_weekly_summary(patient.id)
    end
  end

  defp insert_summary(patient, type, days_ago: days_ago) do
    period_start =
      DateTime.utc_now()
      |> DateTime.add(-days_ago, :day)
      |> DateTime.truncate(:second)

    period_end = DateTime.add(period_start, 7, :day)

    {:ok, summary} =
      Clinical.save_summary(%{
        period_start: period_start,
        period_end: period_end,
        summary_text: "Resumen #{type} #{days_ago}",
        status_level: "stable",
        type: type,
        patient_id: patient.id
      })

    summary
  end

  # ----------------------------------------------------------------
  # save_message/7 — transactional inbound emission
  # (sdd/telegram-rag-ingestion-262, Slice 2, AD2/AD3, tasks 4.1-4.4)
  # ----------------------------------------------------------------

  describe "save_message/7 — transactional inbound emission (Slice 2)" do
    setup do
      {:ok, professional} =
        Accounts.create_professional(%{
          email: "slice2-#{System.unique_integer([:positive])}@alethea.com",
          password: "supersecret12",
          full_name: "Dra. Slice2"
        })

      {:ok, kek} = Accounts.load_professional_kek(professional)

      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "Paciente Slice2 #{System.unique_integer([:positive])}",
            "professional_id" => professional.id
          },
          kek
        )

      {:ok, dek} = Accounts.load_patient_dek(patient, kek)

      %{professional: professional, patient: patient, dek: dek}
    end

    test "inbound: commits the Message row and enqueues exactly one outbox job pinned to the message id (task 4.1)",
         %{patient: patient, dek: dek} do
      assert {:ok, message} =
               Clinical.save_message(patient, "hola, buen día", dek, "inbound", "spontaneous")

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{
          "event" => "patient_message_received",
          "resource_type" => "patient_message",
          "resource_id" => message.id,
          "patient_id" => patient.id,
          "professional_id" => patient.professional_id
        }
      )
    end

    test "outbound: commits the Message row via the untouched bare Repo.insert path, enqueues NO outbox job (task 4.2, AD2)",
         %{patient: patient, dek: dek} do
      assert {:ok, _message} =
               Clinical.save_message(patient, "respuesta clínica", dek, "outbound", "elicited")

      refute_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "duplicate telegram_message_id: surfaces the same %Ecto.Changeset{} shape the worker's duplicate-detection branches on; no outbox job enqueued (task 4.3, AD3)",
         %{patient: patient, dek: dek} do
      assert {:ok, _first} =
               Clinical.save_message(
                 patient,
                 "primer mensaje",
                 dek,
                 "inbound",
                 "spontaneous",
                 nil,
                 "dup-telegram-id-1"
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               Clinical.save_message(
                 patient,
                 "mensaje repetido",
                 dek,
                 "inbound",
                 "spontaneous",
                 nil,
                 "dup-telegram-id-1"
               )

      assert Keyword.has_key?(changeset.errors, :telegram_message_id)

      # AD3: the exact PHI-safe shape `AletheaJobs.SafeReason.for_log/1`
      # renders for a genuine changeset — no raw 4-tuple, no `changes`
      # leak. Confirms a Multi-remapped changeset round-trips through
      # `SafeReason.for_log/1` identically to a bare `Repo.insert`
      # changeset (the worker's existing duplicate-detection code path
      # is unaffected by the Multi conversion).
      assert SafeReason.for_log(changeset) == "[:telegram_message_id]"
      refute SafeReason.for_log(changeset) =~ "changes:"
      refute SafeReason.for_log(changeset) =~ "%Ecto.Changeset"

      # Only one outbox job total — the one from the FIRST (successful)
      # insert. The failed second attempt enqueued nothing.
      jobs = all_enqueued(worker: ClinicalRecordOutboxWorker)
      assert length(jobs) == 1
    end

    test "atomicity: a forced failure on the outbox-event insert step rolls back the Message row too (task 4.4)",
         %{patient: patient, dek: dek, professional: professional} do
      # `Outbox.event/3` is a plain function (not a Mox-mockable
      # port/behaviour) — there is no seam to swap in a "stubbed
      # builder" that returns a broken changeset without reaching into
      # private internals (the same constraint `ClinicalRecordTest`'s
      # "create_target_behavior/3 — atomicity" describe block already
      # documented for `Alethea.ClinicalRecord`'s own outbox Multi).
      # Mirroring that precedent exactly: force a genuine Postgres
      # CHECK-constraint violation on `oban_jobs`, scoped to THIS
      # test's unique `professional_id` so no other concurrently
      # sandboxed test's job inserts are affected.
      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT clinical_test_force_outbox_failure " <>
          "CHECK (args ->> 'professional_id' <> '#{professional.id}')"
      )

      assert_raise Ecto.ConstraintError, fn ->
        Clinical.save_message(patient, "nunca persiste", dek, "inbound", "spontaneous")
      end

      assert Repo.aggregate(from(m in Message, where: m.patient_id == ^patient.id), :count) == 0
    end
  end
end
