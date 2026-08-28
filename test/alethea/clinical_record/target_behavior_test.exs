defmodule Alethea.ClinicalRecord.TargetBehaviorTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.TargetBehavior`
  (sdd/clinical-record-foundation, task 2.1). Pure changeset
  assertions — no DB round-trip needed here; the encrypted create
  flow (`ClinicalRecord.create_target_behavior/3`) lands in PR2.
  """
  use Alethea.DataCase, async: true

  alias Alethea.ClinicalRecord.TargetBehavior

  @valid_attrs %{
    encrypted_description: <<1, 2, 3>>,
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields" do
      changeset = TargetBehavior.changeset(%TargetBehavior{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :encrypted_description) == <<1, 2, 3>>
      assert get_change(changeset, :patient_id) == @valid_attrs.patient_id
      assert get_change(changeset, :professional_id) == @valid_attrs.professional_id
    end

    test "encryption_version defaults to 1 when not cast" do
      changeset = TargetBehavior.changeset(%TargetBehavior{}, @valid_attrs)

      assert changeset.valid?
      assert %TargetBehavior{encryption_version: 1} = Ecto.Changeset.apply_changes(changeset)
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects a missing encrypted_description" do
      changeset =
        TargetBehavior.changeset(
          %TargetBehavior{},
          Map.delete(@valid_attrs, :encrypted_description)
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_description
    end

    test "rejects a missing patient_id" do
      changeset =
        TargetBehavior.changeset(%TargetBehavior{}, Map.delete(@valid_attrs, :patient_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "rejects a missing professional_id" do
      changeset =
        TargetBehavior.changeset(%TargetBehavior{}, Map.delete(@valid_attrs, :professional_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).professional_id
    end
  end
end
