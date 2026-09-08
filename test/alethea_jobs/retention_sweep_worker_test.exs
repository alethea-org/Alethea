defmodule AletheaJobs.RetentionSweepWorkerTest do
  @moduledoc """
  RED-phase specs for `AletheaJobs.RetentionSweepWorker`
  (sdd/clinical-record-retention, GitHub #197, Phase 3/Slice C, task
  3.10): inert when `:retention_sweep_enabled` is `false`; dry-run
  default reports counts and writes nothing; both guards hold
  simultaneously (design's rollback-plan requirement — not just one).
  """
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord.TargetBehavior
  alias Alethea.Repo
  alias AletheaJobs.RetentionSweepWorker

  @password "supersecret12"
  @baseline_days 3650

  setup do
    original = Application.get_env(:alethea, :retention_sweep_enabled, false)
    on_exit(fn -> Application.put_env(:alethea, :retention_sweep_enabled, original) end)

    professional = create_professional!()
    patient = create_patient!(professional)

    %{professional: professional, patient: patient}
  end

  describe "job options" do
    test "queue is :clinical_record_retention with max_attempts 1" do
      changeset = RetentionSweepWorker.new(%{})

      assert Ecto.Changeset.get_change(changeset, :queue) == "clinical_record_retention"
      assert Ecto.Changeset.get_change(changeset, :max_attempts) == 1
    end
  end

  describe "guard 1 — :retention_sweep_enabled is false (the default)" do
    test "does nothing at all, even with an eligible record present and dry_run explicitly false",
         %{professional: professional, patient: patient} do
      Application.put_env(:alethea, :retention_sweep_enabled, false)
      target_behavior = insert_old_target_behavior!(patient, professional)

      assert :ok = perform_job(RetentionSweepWorker, %{"dry_run" => false})

      assert Repo.get(TargetBehavior, target_behavior.id)
    end
  end

  describe "guard 2 — dry-run is the default even when enabled" do
    test "an enabled sweep with no dry_run arg (the cron-scheduled shape) reports counts and deletes nothing",
         %{professional: professional, patient: patient} do
      Application.put_env(:alethea, :retention_sweep_enabled, true)
      target_behavior = insert_old_target_behavior!(patient, professional)

      assert :ok = perform_job(RetentionSweepWorker, %{})

      assert Repo.get(TargetBehavior, target_behavior.id)
    end

    test "an enabled sweep with dry_run explicitly true also reports counts and deletes nothing",
         %{professional: professional, patient: patient} do
      Application.put_env(:alethea, :retention_sweep_enabled, true)
      target_behavior = insert_old_target_behavior!(patient, professional)

      assert :ok = perform_job(RetentionSweepWorker, %{"dry_run" => true})

      assert Repo.get(TargetBehavior, target_behavior.id)
    end
  end

  describe "both guards down — the only way an actual sweep runs" do
    test "enabled AND dry_run false legally deletes every currently-eligible record", %{
      professional: professional,
      patient: patient
    } do
      Application.put_env(:alethea, :retention_sweep_enabled, true)
      target_behavior = insert_old_target_behavior!(patient, professional)

      assert :ok = perform_job(RetentionSweepWorker, %{"dry_run" => false})

      refute Repo.get(TargetBehavior, target_behavior.id)
    end

    test "a fresh (ineligible) record is left untouched by a real sweep", %{
      professional: professional,
      patient: patient
    } do
      Application.put_env(:alethea, :retention_sweep_enabled, true)

      fresh =
        insert_target_behavior_at!(patient, professional, now())

      assert :ok = perform_job(RetentionSweepWorker, %{"dry_run" => false})

      assert Repo.get(TargetBehavior, fresh.id)
    end

    test "a held patient's eligible record is skipped by a real sweep", %{
      professional: professional,
      patient: patient
    } do
      Application.put_env(:alethea, :retention_sweep_enabled, true)
      target_behavior = insert_old_target_behavior!(patient, professional)
      {:ok, _lifecycle} = Alethea.ClinicalRecord.Lifecycle.apply_hold(professional, patient.id)

      assert :ok = perform_job(RetentionSweepWorker, %{"dry_run" => false})

      assert Repo.get(TargetBehavior, target_behavior.id)
    end
  end

  defp insert_old_target_behavior!(patient, professional) do
    insert_target_behavior_at!(patient, professional, days_ago(@baseline_days + 1))
  end

  defp insert_target_behavior_at!(patient, professional, inserted_at) do
    attrs = %{
      id: Ecto.UUID.generate(),
      encrypted_description: <<1, 2, 3>>,
      encryption_version: 1,
      patient_id: patient.id,
      professional_id: professional.id,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }

    {1, [row]} = Repo.insert_all(TargetBehavior, [attrs], returning: true)
    row
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "sweep-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Sweep"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end
end
