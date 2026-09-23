defmodule Alethea.ClinicalRecord.DismissedEvidenceSuggestionTest do
  use Alethea.DataCase, async: true

  alias Alethea.ClinicalRecord.DismissedEvidenceSuggestion

  describe "changeset/2" do
    test "is valid with a chunk id and defaults dismissed_at" do
      changeset =
        DismissedEvidenceSuggestion.changeset(%DismissedEvidenceSuggestion{}, %{
          patient_id: Ecto.UUID.generate(),
          professional_id: Ecto.UUID.generate(),
          target_behavior_id: Ecto.UUID.generate(),
          chunk_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert %DateTime{} = get_change(changeset, :dismissed_at)
    end

    test "is valid with resource attributes" do
      changeset =
        DismissedEvidenceSuggestion.changeset(%DismissedEvidenceSuggestion{}, %{
          patient_id: Ecto.UUID.generate(),
          professional_id: Ecto.UUID.generate(),
          target_behavior_id: Ecto.UUID.generate(),
          resource_id: Ecto.UUID.generate(),
          resource_type: "clinical_note",
          dismissed_at: ~U[2026-09-23 16:30:00.123456Z]
        })

      assert changeset.valid?
      assert get_change(changeset, :dismissed_at) == ~U[2026-09-23 16:30:00.123456Z]
    end

    test "requires patient, professional, and target behavior" do
      changeset =
        DismissedEvidenceSuggestion.changeset(%DismissedEvidenceSuggestion{}, %{
          chunk_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
      assert "can't be blank" in errors_on(changeset).professional_id
      assert "can't be blank" in errors_on(changeset).target_behavior_id
    end

    test "requires at least one of chunk_id or resource_id" do
      changeset =
        DismissedEvidenceSuggestion.changeset(%DismissedEvidenceSuggestion{}, %{
          patient_id: Ecto.UUID.generate(),
          professional_id: Ecto.UUID.generate(),
          target_behavior_id: Ecto.UUID.generate()
        })

      refute changeset.valid?

      assert "at least one of chunk_id or resource_id must be present" in errors_on(changeset).chunk_id
    end
  end
end
