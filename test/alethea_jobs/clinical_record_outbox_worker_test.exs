defmodule AletheaJobs.ClinicalRecordOutboxWorkerTest do
  @moduledoc """
  Tests for `AletheaJobs.ClinicalRecordOutboxWorker` (sdd/clinical-record-foundation,
  task 2.5). GREEN-only per the tasks artifact — this worker is a
  deliberate no-op until #196 lands its own projection consumer.
  """
  use ExUnit.Case, async: true

  alias AletheaJobs.ClinicalRecordOutboxWorker

  describe "perform/1" do
    test "returns :ok for a target_behavior_created job with the 5-key identifier args" do
      job = %Oban.Job{
        args: %{
          "event" => "target_behavior_created",
          "resource_type" => "target_behavior",
          "resource_id" => Ecto.UUID.generate(),
          "patient_id" => Ecto.UUID.generate(),
          "professional_id" => Ecto.UUID.generate()
        }
      }

      assert :ok = ClinicalRecordOutboxWorker.perform(job)
    end

    test "returns :ok for a clinical_note_created job (triangulation — different event value)" do
      job = %Oban.Job{
        args: %{
          "event" => "clinical_note_created",
          "resource_type" => "clinical_note",
          "resource_id" => Ecto.UUID.generate(),
          "patient_id" => Ecto.UUID.generate(),
          "professional_id" => Ecto.UUID.generate()
        }
      }

      assert :ok = ClinicalRecordOutboxWorker.perform(job)
    end

    test "raises FunctionClauseError for args missing an identifier key" do
      job = %Oban.Job{
        args: %{
          "event" => "target_behavior_created",
          "resource_type" => "target_behavior",
          "resource_id" => Ecto.UUID.generate()
        }
      }

      assert_raise FunctionClauseError, fn -> ClinicalRecordOutboxWorker.perform(job) end
    end
  end

  test "queue is :clinical_record_outbox with max_attempts 1" do
    changeset =
      ClinicalRecordOutboxWorker.new(%{
        "event" => "target_behavior_created",
        "resource_type" => "target_behavior",
        "resource_id" => Ecto.UUID.generate(),
        "patient_id" => Ecto.UUID.generate(),
        "professional_id" => Ecto.UUID.generate()
      })

    assert Ecto.Changeset.get_change(changeset, :queue) == "clinical_record_outbox"
    assert Ecto.Changeset.get_change(changeset, :max_attempts) == 1
  end
end
