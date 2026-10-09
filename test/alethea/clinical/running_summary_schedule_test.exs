defmodule Alethea.Clinical.RunningSummaryScheduleTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.FoundationTestHelper
  import ExUnit.CaptureLog
  import Alethea.RunningSummaryHelper

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.Clinical.RunningSummary
  alias Alethea.Clinical.RunningSummary.Snapshot
  alias AletheaJobs.RunningSummaryWorker

  setup do
    professional = legacy_professional_fixture()
    patient = legacy_patient_fixture(professional)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    %{patient: patient, dek: dek}
  end

  defp jobs, do: all_enqueued(worker: RunningSummaryWorker)

  describe "schedule_if_due/2 triggers" do
    test "below the batch size enqueues nothing; at ten inbounds enqueues one job", ctx do
      seed(ctx.patient, ctx.dek, 1..9)
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert jobs() == []

      seed(ctx.patient, ctx.dek, 10..10)
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [%{args: args}] = jobs()
      assert args == %{"patient_id" => ctx.patient.id}
    end

    test "with a stored row it needs ten more inbounds than the covered count", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..19)
      put_row(ctx.patient, ctx.dek, valid_summary(), :first, 0, 10, Enum.at(inbounds, 9))

      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert jobs() == []

      seed(ctx.patient, ctx.dek, 20..20)
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end

    test "a count below the covered count (deleted messages) enqueues", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..12)
      put_row(ctx.patient, ctx.dek, valid_summary(), :first, 0, 20, Enum.at(inbounds, 9))

      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end

    test "a row whose anchor message is gone (NULL) enqueues", ctx do
      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..10)
      anchor = Enum.at(inbounds, 9)
      put_row(ctx.patient, ctx.dek, valid_summary(), :first, 0, 10, anchor)
      Repo.update_all(Snapshot, set: [covered_through_message_id: nil])

      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end

    test "crisis inbounds count toward the batch", ctx do
      seed(ctx.patient, ctx.dek, 1..9)
      seed(ctx.patient, ctx.dek, 10..10, inbound_behavior: "crisis_bypass")

      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end
  end

  describe "schedule_if_due/2 idempotency and safety" do
    test "a second trigger while the job is available adds no job", ctx do
      seed(ctx.patient, ctx.dek, 1..10)
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end

    test "a replayed inbound does not change the count nor enqueue", ctx do
      seed(ctx.patient, ctx.dek, 1..9)

      {:ok, _} =
        Clinical.save_message(ctx.patient, "x", ctx.dek, "inbound", "spontaneous", nil, "77")

      before = Repo.aggregate(Alethea.Clinical.Message, :count)

      assert {:error, _} =
               Clinical.save_message(
                 ctx.patient,
                 "x",
                 ctx.dek,
                 "inbound",
                 "spontaneous",
                 nil,
                 "77"
               )

      assert Repo.aggregate(Alethea.Clinical.Message, :count) == before

      # 9 seeded + 1 distinct inbound = 10 -> exactly one job, not two.
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end

    test "never raises: malformed id and unknown patient return :ok and enqueue nothing" do
      assert :ok = RunningSummary.schedule_if_due("not-a-uuid", "abcd1234")
      assert :ok = RunningSummary.schedule_if_due(Ecto.UUID.generate(), "abcd1234")
      assert jobs() == []
    end
  end

  describe "enabled?/0 (#394 provider pin)" do
    test "is true when the local endpoint resolves" do
      assert RunningSummary.enabled?()
    end

    test "is false without a local endpoint, whatever the guided provider" do
      disable_local_endpoint()
      Application.put_env(:alethea, Alethea.AI.Chains.GuidedConversationChain, provider: :cloud)

      refute RunningSummary.enabled?()
    end

    test "is false for a blank local endpoint" do
      disable_local_endpoint()
      Application.put_env(:alethea, Alethea.AI.LLMConfig, local: [endpoint_url: "   "])

      refute RunningSummary.enabled?()
    end

    test "disabled: ten inbounds enqueue nothing and the call still returns :ok", ctx do
      seed(ctx.patient, ctx.dek, 1..10)
      disable_local_endpoint()

      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert jobs() == []

      # The same ten inbounds do enqueue once the endpoint is back.
      Application.put_env(:alethea, :env, :test)
      assert :ok = RunningSummary.schedule_if_due(ctx.patient.id, "abcd1234")
      assert [_one] = jobs()
    end
  end

  describe "log_boot_status/0 (#394 provider pin)" do
    test "logs once that the summary is disabled, naming no patient data" do
      disable_local_endpoint()

      log = capture_log(fn -> assert :ok = RunningSummary.log_boot_status() end)

      assert log =~ "running summary disabled"
      assert log =~ "no local LLM endpoint"
      assert length(String.split(log, "running summary disabled")) == 2
    end

    test "logs nothing while the local endpoint resolves" do
      log = capture_log(fn -> assert :ok = RunningSummary.log_boot_status() end)

      refute log =~ "running summary"
    end
  end

  describe "plan/1" do
    test "not due, first build aligned to the latest multiple of ten, and reset", ctx do
      assert :not_due = RunningSummary.plan(ctx.patient)

      [_ | _] = inbounds = seed(ctx.patient, ctx.dek, 1..25)
      assert {:build, plan} = RunningSummary.plan(ctx.patient)
      assert %{mode: :first, expected: 0, target_count: 20} = plan
      assert plan.target.id == Enum.at(inbounds, 19).id

      put_row(ctx.patient, ctx.dek, valid_summary(), :first, 0, 20, Enum.at(inbounds, 19))
      assert :not_due = RunningSummary.plan(ctx.patient)

      Repo.delete_all(Alethea.Clinical.Message)
      seed(ctx.patient, ctx.dek, 1..12)
      assert {:reset, 20} = RunningSummary.plan(ctx.patient)
    end
  end
end
