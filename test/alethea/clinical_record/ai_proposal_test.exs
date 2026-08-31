defmodule Alethea.ClinicalRecord.AIProposalTest do
  @moduledoc """
  Schema/changeset tests for `Alethea.ClinicalRecord.AIProposal`
  (sdd/alethea/issue-195-clinical-review-workbench, PR1b task 2.3).

  Encodes design A6/D3 structurally, not just by convention:

    * The insert changeset forces `status` to `"pending"` via `put_change/3`
      — no attrs map can make a freshly-inserted proposal anything else.
    * `update_changeset/2` casts only `encrypted_text` and `status` — it
      never casts `encrypted_original_text`, so an edit cannot destroy the
      original AI output (spec: "original_text (write-once) is unchanged").
  """
  use Alethea.DataCase, async: true

  alias Alethea.ClinicalRecord.AIProposal

  @valid_attrs %{
    encrypted_original_text: <<1, 2, 3>>,
    encrypted_text: <<1, 2, 3>>,
    model_version: "phi-4-mini",
    occurred_at: DateTime.utc_now(),
    patient_id: Ecto.UUID.generate(),
    professional_id: Ecto.UUID.generate(),
    target_behavior_id: Ecto.UUID.generate()
  }

  describe "changeset/2 — happy path forces status to pending" do
    test "is valid and status is always pending regardless of attrs" do
      changeset = AIProposal.changeset(%AIProposal{}, @valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :status) == "pending"
    end

    test "ignores a status supplied in attrs — insert can never produce accepted" do
      attrs = Map.put(@valid_attrs, :status, "accepted")

      changeset = AIProposal.changeset(%AIProposal{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :status) == "pending"
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects a missing encrypted_original_text" do
      changeset =
        AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :encrypted_original_text))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_original_text
    end

    test "rejects a missing encrypted_text" do
      changeset = AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :encrypted_text))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).encrypted_text
    end

    test "rejects a missing model_version" do
      changeset = AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :model_version))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).model_version
    end

    test "rejects a missing occurred_at" do
      changeset = AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :occurred_at))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).occurred_at
    end

    test "rejects a missing patient_id" do
      changeset = AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :patient_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).patient_id
    end

    test "rejects a missing professional_id" do
      changeset =
        AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :professional_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).professional_id
    end

    test "rejects a missing target_behavior_id" do
      changeset =
        AIProposal.changeset(%AIProposal{}, Map.delete(@valid_attrs, :target_behavior_id))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_behavior_id
    end
  end

  describe "update_changeset/2 — write-once original_text (design D3)" do
    setup do
      proposal = %AIProposal{
        encrypted_original_text: <<1, 2, 3>>,
        encrypted_text: <<1, 2, 3>>,
        status: "pending",
        model_version: "phi-4-mini",
        patient_id: Ecto.UUID.generate(),
        professional_id: Ecto.UUID.generate(),
        target_behavior_id: Ecto.UUID.generate()
      }

      %{proposal: proposal}
    end

    test "casts encrypted_text and status, moving to edited", %{proposal: proposal} do
      changeset =
        AIProposal.update_changeset(proposal, %{
          encrypted_text: <<9, 9, 9>>,
          status: "edited"
        })

      assert changeset.valid?
      assert get_change(changeset, :encrypted_text) == <<9, 9, 9>>
      assert get_change(changeset, :status) == "edited"
    end

    test "ignores an attempt to overwrite encrypted_original_text via update_changeset", %{
      proposal: proposal
    } do
      changeset =
        AIProposal.update_changeset(proposal, %{
          encrypted_text: <<9, 9, 9>>,
          encrypted_original_text: <<0, 0, 0>>,
          status: "edited"
        })

      refute Map.has_key?(changeset.changes, :encrypted_original_text)
      assert proposal.encrypted_original_text == <<1, 2, 3>>
    end

    test "accepts a transition straight to accepted", %{proposal: proposal} do
      changeset = AIProposal.update_changeset(proposal, %{status: "accepted"})

      assert changeset.valid?
      assert get_change(changeset, :status) == "accepted"
    end

    test "accepts a soft discard, keeping the row (design D5)", %{proposal: proposal} do
      changeset = AIProposal.update_changeset(proposal, %{status: "discarded"})

      assert changeset.valid?
      assert get_change(changeset, :status) == "discarded"
    end

    test "rejects a status outside the fixed vocabulary", %{proposal: proposal} do
      changeset = AIProposal.update_changeset(proposal, %{status: "confirmed"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end
  end
end
