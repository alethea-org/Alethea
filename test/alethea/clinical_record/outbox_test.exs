defmodule Alethea.ClinicalRecord.OutboxTest do
  @moduledoc """
  Tests for `Alethea.ClinicalRecord.Outbox` (sdd/clinical-record-foundation,
  task 2.4). Proves the `Map.take/2` allowlist: even when the source
  record carries encrypted content, the built job `args` can only ever
  contain the five identifier keys.
  """
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.{ClinicalNote, ConsultationEvidence, Outbox, TargetBehavior}

  describe "event/2 — target_behavior_created" do
    test "builds a job changeset with identifiers-only args" do
      id = Ecto.UUID.generate()
      patient_id = Ecto.UUID.generate()
      professional_id = Ecto.UUID.generate()

      record = %TargetBehavior{
        id: id,
        patient_id: patient_id,
        professional_id: professional_id,
        encrypted_description: <<1, 2, 3>>
      }

      changeset = Outbox.event("target_behavior_created", record)

      assert changeset.valid?

      assert get_change(changeset, :args) == %{
               "event" => "target_behavior_created",
               "resource_type" => "target_behavior",
               "resource_id" => id,
               "patient_id" => patient_id,
               "professional_id" => professional_id
             }
    end
  end

  describe "event/2 — clinical_note_created (triangulation)" do
    test "builds a job changeset with a different resource_type and no clinical content" do
      id = Ecto.UUID.generate()
      patient_id = Ecto.UUID.generate()
      professional_id = Ecto.UUID.generate()

      record = %ClinicalNote{
        id: id,
        patient_id: patient_id,
        professional_id: professional_id,
        encrypted_body: <<9, 9, 9>>
      }

      changeset = Outbox.event("clinical_note_created", record)
      args = get_change(changeset, :args)

      assert args["resource_type"] == "clinical_note"
      assert args["resource_id"] == id
      refute Map.has_key?(args, "encrypted_body")
      refute Map.has_key?(args, "encrypted_description")
    end
  end

  describe "event/2 — consultation_evidence_created (sdd/alethea/issue-195-clinical-review-workbench, PR1a task 1.5)" do
    test "builds a job changeset with a consultation_evidence resource_type and no source data" do
      id = Ecto.UUID.generate()
      patient_id = Ecto.UUID.generate()
      professional_id = Ecto.UUID.generate()

      record = %ConsultationEvidence{
        id: id,
        patient_id: patient_id,
        professional_id: professional_id,
        source_kind: "clinical_note",
        source_id: Ecto.UUID.generate(),
        encrypted_excerpt: <<7, 7, 7>>
      }

      changeset = Outbox.event("consultation_evidence_created", record)
      args = get_change(changeset, :args)

      assert changeset.valid?
      assert args["resource_type"] == "consultation_evidence"
      assert args["resource_id"] == id
      refute Map.has_key?(args, "encrypted_excerpt")
      refute Map.has_key?(args, "source_id")
    end
  end

  describe "event/2 — allowlist drops non-identifier keys" do
    test "args never contains a details/outcome key even if the record shape widens" do
      record = %TargetBehavior{
        id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate(),
        professional_id: Ecto.UUID.generate(),
        encrypted_description: <<1>>
      }

      changeset = Outbox.event("target_behavior_created", record)
      args = get_change(changeset, :args)

      assert Map.keys(args) |> Enum.sort() ==
               Enum.sort([
                 "event",
                 "resource_type",
                 "resource_id",
                 "patient_id",
                 "professional_id"
               ])

      refute Map.has_key?(args, :__struct__)
    end
  end

  defp get_change(%Ecto.Changeset{} = changeset, field),
    do: Ecto.Changeset.get_change(changeset, field)
end
