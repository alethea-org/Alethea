defmodule Alethea.Triggers.TriggerConstraintsTest do
  @moduledoc """
  Pins the database-level row shape of each trigger kind (#448).

  Every row here is inserted directly into `triggers`, bypassing
  `Alethea.Triggers.Trigger`'s changeset, so the CHECK constraints are the
  only thing that can accept or reject it.
  """

  use Alethea.DataCase, async: true

  import Alethea.TriggersFixtures

  alias Alethea.Repo

  setup do
    %{professional: professional, patient: patient} = fixture_professional_and_patient()
    %{professional: professional, patient: patient}
  end

  describe "valid rows" do
    test "a reactive row without a schedule is accepted", ctx do
      assert {1, _} = insert_raw(ctx, reactive_row())
    end

    test "an active row with a schedule is accepted", ctx do
      assert {1, _} = insert_raw(ctx, active_row())
    end
  end

  describe "triggers_kind_check" do
    test "rejects an unknown kind", ctx do
      assert_check_violation("triggers_kind_check", fn ->
        insert_raw(ctx, Map.put(active_row(), :kind, "proactive"))
      end)
    end
  end

  describe "triggers_active_shape_check" do
    for column <- [:scheduled_at, :timezone, :schedule_type] do
      test "rejects an active row without #{column}", ctx do
        assert_check_violation("triggers_active_shape_check", fn ->
          insert_raw(ctx, Map.put(active_row(), unquote(column), nil))
        end)
      end
    end

    test "rejects an active row carrying a condition", ctx do
      assert_check_violation("triggers_active_shape_check", fn ->
        insert_raw(ctx, Map.put(active_row(), :condition, "ciphertext"))
      end)
    end
  end

  describe "triggers_reactive_shape_check" do
    for column <- [:condition, :cooldown_hours] do
      test "rejects a reactive row without #{column}", ctx do
        assert_check_violation("triggers_reactive_shape_check", fn ->
          insert_raw(ctx, Map.put(reactive_row(), unquote(column), nil))
        end)
      end
    end

    test "rejects a reactive row carrying scheduled_at", ctx do
      assert_check_violation("triggers_reactive_shape_check", fn ->
        insert_raw(ctx, Map.put(reactive_row(), :scheduled_at, now()))
      end)
    end

    test "rejects a reactive row carrying schedule_type", ctx do
      assert_check_violation("triggers_reactive_shape_check", fn ->
        insert_raw(ctx, Map.put(reactive_row(), :schedule_type, "once"))
      end)
    end
  end

  defp active_row do
    %{
      kind: "active",
      scheduled_at: now(),
      timezone: "America/Santiago",
      schedule_type: "once",
      condition: nil,
      cooldown_hours: nil
    }
  end

  defp reactive_row do
    %{
      kind: "reactive",
      scheduled_at: nil,
      timezone: nil,
      schedule_type: nil,
      condition: "ciphertext",
      cooldown_hours: 24
    }
  end

  defp insert_raw(%{professional: professional, patient: patient}, shape) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          patient_id: Ecto.UUID.dump!(patient.id),
          professional_id: Ecto.UUID.dump!(professional.id),
          instruction: "ciphertext",
          status: "active",
          encryption_version: 1,
          approval_revision: 1,
          inserted_at: now(),
          updated_at: now()
        },
        shape
      )

    Repo.insert_all("triggers", [row])
  end

  defp assert_check_violation(constraint, fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == constraint
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
