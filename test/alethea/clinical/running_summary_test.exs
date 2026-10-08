defmodule Alethea.Clinical.RunningSummaryTest do
  use Alethea.DataCase, async: true

  import Alethea.FoundationTestHelper

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.Clinical
  alias Alethea.Clinical.RunningSummary
  alias Alethea.Clinical.RunningSummary.Snapshot
  alias Alethea.ClinicalRecord.Retention
  alias Alethea.Encryption.PatientVault

  @plain "Hechos que la persona relato:\n- salio a caminar con su hermana"

  setup do
    professional = legacy_professional_fixture()
    patient = legacy_patient_fixture(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, message} = Clinical.save_message(patient, "hola", dek, "outbound", "elicited")

    %{professional: professional, patient: patient, dek: dek, message: message}
  end

  defp plan(message, mode, expected, target_count),
    do: %{mode: mode, expected: expected, target_count: target_count, target: message}

  defp seal(text, dek) do
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)
    ciphertext
  end

  defp row_for(patient), do: Repo.get_by(Snapshot, patient_id: patient.id)

  defp insert_first(ctx, text \\ @plain, count \\ 10) do
    :ok =
      RunningSummary.write(
        plan(ctx.message, :first, 0, count),
        seal(text, ctx.dek),
        ctx.patient
      )
  end

  describe "storage" do
    test "raw column holds ciphertext, never the plaintext", ctx do
      insert_first(ctx)

      %{rows: [[raw]]} =
        Repo.query!("SELECT encrypted_summary FROM running_summaries WHERE patient_id = $1", [
          Ecto.UUID.dump!(ctx.patient.id)
        ])

      assert is_binary(raw)
      refute raw =~ "hermana"
      refute raw =~ "Hechos"
    end

    test "round trips under the journaling patient DEK with encryption_version 1", ctx do
      insert_first(ctx)

      row = row_for(ctx.patient)
      assert row.encryption_version == 1
      assert row.covered_inbound_count == 10
      assert row.covered_through_message_id == ctx.message.id
      assert row.professional_id == ctx.professional.id
      assert {:ok, @plain} = PatientVault.decrypt(row.encrypted_summary, ctx.dek)
      assert {:ok, @plain} = RunningSummary.load_usable(ctx.patient)
    end

    test "load_usable audits the running_summary_loading reason; none without a row", ctx do
      assert :none = RunningSummary.load_usable(ctx.patient)
      assert audit_reasons(ctx.patient) == []

      insert_first(ctx)
      assert {:ok, @plain} = RunningSummary.load_usable(ctx.patient)
      assert audit_reasons(ctx.patient) == ["running_summary_loading"]
    end

    test "load_usable surfaces a decrypt failure as an atom error", ctx do
      :ok =
        RunningSummary.write(
          plan(ctx.message, :first, 0, 10),
          seal(@plain, :crypto.strong_rand_bytes(32)),
          ctx.patient
        )

      assert {:error, reason} = RunningSummary.load_usable(ctx.patient)
      assert is_atom(reason)
    end

    test "deleting the patient cascades the row", ctx do
      insert_first(ctx)
      assert row_for(ctx.patient)

      Repo.delete!(ctx.patient)

      refute Repo.get_by(Snapshot, patient_id: ctx.patient.id)
    end

    test "Inspect hides the summary and the ciphertext" do
      snapshot = %Snapshot{summary: "texto-secreto", encrypted_summary: <<1, 2, 3>>}

      refute inspect(snapshot) =~ "texto-secreto"
      refute inspect(snapshot) =~ "<<1, 2, 3>>"
    end
  end

  describe "CAS write" do
    test "a stale expected count returns :stale and leaves the row unchanged", ctx do
      insert_first(ctx)
      before = row_for(ctx.patient)

      assert {:error, :stale} =
               RunningSummary.write(
                 plan(ctx.message, :incremental, 5, 15),
                 seal("otro", ctx.dek),
                 ctx.patient
               )

      assert row_for(ctx.patient) == before
    end

    test "an advance from the matching expected count lands", ctx do
      insert_first(ctx)

      assert :ok =
               RunningSummary.write(
                 plan(ctx.message, :incremental, 10, 20),
                 seal("nuevo", ctx.dek),
                 ctx.patient
               )

      assert row_for(ctx.patient).covered_inbound_count == 20
      assert {:ok, "nuevo"} = RunningSummary.load_usable(ctx.patient)
    end

    test "new <= expected is rejected and the row is unchanged", ctx do
      insert_first(ctx)
      before = row_for(ctx.patient)

      for target <- [10, 9] do
        assert {:error, :persist_failed} =
                 RunningSummary.write(
                   plan(ctx.message, :incremental, 10, target),
                   seal("x", ctx.dek),
                   ctx.patient
                 )
      end

      assert row_for(ctx.patient) == before
    end

    test "two first writes leave exactly one row; the loser is stale", ctx do
      assert :ok =
               RunningSummary.write(
                 plan(ctx.message, :first, 0, 10),
                 seal("a", ctx.dek),
                 ctx.patient
               )

      assert {:error, :stale} =
               RunningSummary.write(
                 plan(ctx.message, :first, 0, 10),
                 seal("b", ctx.dek),
                 ctx.patient
               )

      assert Repo.aggregate(from(s in Snapshot, where: s.patient_id == ^ctx.patient.id), :count) ==
               1

      assert {:ok, "a"} = RunningSummary.load_usable(ctx.patient)
    end

    test "two CAS writes from the same expected count: exactly one lands", ctx do
      insert_first(ctx)

      results =
        for text <- ["uno", "dos"] do
          RunningSummary.write(
            plan(ctx.message, :incremental, 10, 20),
            seal(text, ctx.dek),
            ctx.patient
          )
        end

      assert Enum.sort(results) == Enum.sort([:ok, {:error, :stale}])
      assert {:ok, "uno"} = RunningSummary.load_usable(ctx.patient)
    end

    test "reset deletes the row only when the observed count matches", ctx do
      insert_first(ctx)

      assert {:error, :stale} = RunningSummary.reset(ctx.patient, 30)
      assert RunningSummary.exists?(ctx.patient)

      assert :ok = RunningSummary.reset(ctx.patient, 10)
      refute RunningSummary.exists?(ctx.patient)
    end
  end

  describe "tenant isolation" do
    setup ctx do
      other_pro = legacy_professional_fixture()
      other_patient = legacy_patient_fixture(other_pro)
      Map.merge(ctx, %{other_pro: other_pro, other_patient: other_patient})
    end

    test "insert_all with another professional's id violates the composite FK", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert_raise Postgrex.Error,
                   ~r/foreign_key_violation|running_summaries_patient_id_fkey/,
                   fn ->
                     Repo.insert_all(Snapshot, [
                       %{
                         id: Ecto.UUID.generate(),
                         patient_id: ctx.patient.id,
                         professional_id: ctx.other_pro.id,
                         encrypted_summary: <<1>>,
                         encryption_version: 1,
                         covered_inbound_count: 10,
                         inserted_at: now,
                         updated_at: now
                       }
                     ])
                   end
    end

    test "exists?/1 and load_usable/1 never return another patient's row", ctx do
      insert_first(ctx)

      assert RunningSummary.exists?(ctx.patient)
      refute RunningSummary.exists?(ctx.other_patient)
      assert :none = RunningSummary.load_usable(ctx.other_patient)
    end

    test "a patient struct with a mismatched professional never reads the row", ctx do
      insert_first(ctx)
      forged = %{ctx.patient | professional_id: ctx.other_pro.id}

      refute RunningSummary.exists?(forged)
      assert :none = RunningSummary.load_usable(forged)
    end

    test "changing patients.professional_id fails closed while a summary row exists", ctx do
      insert_first(ctx)

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(
          from(p in Alethea.Accounts.Patient, where: p.id == ^ctx.patient.id),
          set: [professional_id: ctx.other_pro.id]
        )
      end
    end

    test "after delete_for_patient/1 the professional change succeeds", ctx do
      insert_first(ctx)
      assert :ok = RunningSummary.delete_for_patient(ctx.patient)
      refute RunningSummary.exists?(ctx.patient)

      assert {1, _} =
               Repo.update_all(
                 from(p in Alethea.Accounts.Patient, where: p.id == ^ctx.patient.id),
                 set: [professional_id: ctx.other_pro.id]
               )
    end

    test "delete_for_patient/1 leaves other patients' rows alone", ctx do
      insert_first(ctx)
      assert :ok = RunningSummary.delete_for_patient(ctx.other_patient)
      assert RunningSummary.exists?(ctx.patient)
    end
  end

  describe "no side channels" do
    test "writing and refreshing a row enqueues no job", ctx do
      jobs_before = Repo.aggregate("oban_jobs", :count)

      insert_first(ctx)

      :ok =
        RunningSummary.write(
          plan(ctx.message, :incremental, 10, 20),
          seal("refresh", ctx.dek),
          ctx.patient
        )

      assert Repo.aggregate("oban_jobs", :count) == jobs_before
    end

    test "Retention does not register the summary table" do
      refute "running_summary" in Retention.resource_types()
      refute "running_summaries" in Retention.resource_types()
    end
  end

  defp audit_reasons(patient) do
    AuditLog
    |> where([a], a.resource_id == ^patient.id and a.action == "PII_DECRYPT")
    |> Repo.all()
    |> Enum.map(& &1.details["reason"])
  end
end
