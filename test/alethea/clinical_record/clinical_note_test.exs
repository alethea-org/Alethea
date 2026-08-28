defmodule Alethea.ClinicalRecord.ClinicalNoteTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.ClinicalNote`
  (sdd/clinical-record-foundation, task 2.2). Create-only: there is
  no update changeset, and `timestamps/1` on the schema omits
  `updated_at` — DB-level immutability enforcement (the `BEFORE
  UPDATE` trigger) is proven in PR3 (task 5.2), not here.
  """
  use Alethea.DataCase, async: true

  alias Alethea.ClinicalRecord.ClinicalNote

  @valid_attrs %{
    encrypted_body: <<9, 8, 7>>,
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path" do
    test "is valid with all required fields" do
      changeset = ClinicalNote.changeset(%ClinicalNote{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :encrypted_body) == <<9, 8, 7>>
      assert get_change(changeset, :patient_id) == @valid_attrs.patient_id
      assert get_change(changeset, :professional_id) == @valid_attrs.professional_id
    end

    test "encryption_version defaults to 1 when not cast" do
      changeset = ClinicalNote.changeset(%ClinicalNote{}, @valid_attrs)

      assert changeset.valid?
      assert %ClinicalNote{encryption_version: 1} = Ecto.Changeset.apply_changes(changeset)
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects a missing encrypted_body" do
      changeset =
        ClinicalNote.changeset(%ClinicalNote{}, Map.delete(@valid_attrs, :encrypted_body))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_body
    end

    test "rejects a missing patient_id" do
      changeset = ClinicalNote.changeset(%ClinicalNote{}, Map.delete(@valid_attrs, :patient_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "rejects a missing professional_id" do
      changeset =
        ClinicalNote.changeset(%ClinicalNote{}, Map.delete(@valid_attrs, :professional_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).professional_id
    end
  end

  describe "no update path exists (structural immutability)" do
    test "the module exports no update_changeset/2 function" do
      refute function_exported?(ClinicalNote, :update_changeset, 2)
    end
  end
end
