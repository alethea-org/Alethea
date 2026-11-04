defmodule Alethea.Triggers.TriggerTest do
  @moduledoc """
  Changeset rules per trigger kind (#448): schedule fields are required only
  for active triggers, the condition and cooldown only for reactive ones, and
  `kind` is never castable from params.
  """

  use ExUnit.Case, async: true

  alias Alethea.Triggers.Trigger

  @ids %{patient_id: Ecto.UUID.generate(), professional_id: Ecto.UUID.generate()}

  describe "changeset/2 — active kind" do
    test "is the default kind and has no schedule_type default" do
      assert %Trigger{}.kind == "active"
      assert is_nil(%Trigger{}.schedule_type)
    end

    test "requires scheduled_at, timezone and schedule_type" do
      changeset = Trigger.changeset(%Trigger{}, Map.put(@ids, :instruction, "cipher"))

      refute changeset.valid?
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :scheduled_at)
      assert Map.has_key?(errors, :timezone)
      assert Map.has_key?(errors, :schedule_type)
    end

    test "rejects a condition" do
      changeset = Trigger.changeset(%Trigger{}, Map.put(active_attrs(), :condition, "cipher"))

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :condition)
    end

    test "accepts a complete scheduled trigger" do
      assert Trigger.changeset(%Trigger{}, active_attrs()).valid?
    end

    test "ignores kind in params" do
      changeset = Trigger.changeset(%Trigger{}, Map.put(active_attrs(), :kind, "reactive"))

      assert Ecto.Changeset.get_field(changeset, :kind) == "active"
    end
  end

  describe "reactive_changeset/2" do
    test "sets kind to reactive and accepts a trigger without a schedule" do
      changeset = Trigger.reactive_changeset(%Trigger{}, reactive_attrs())

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :kind) == "reactive"
      assert is_nil(Ecto.Changeset.get_field(changeset, :schedule_type))
      assert is_nil(Ecto.Changeset.get_field(changeset, :scheduled_at))
    end

    test "requires condition and cooldown_hours" do
      changeset =
        Trigger.reactive_changeset(
          %Trigger{},
          reactive_attrs() |> Map.delete(:condition) |> Map.delete(:cooldown_hours)
        )

      refute changeset.valid?
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :condition)
      assert Map.has_key?(errors, :cooldown_hours)
    end

    test "rejects a non-positive cooldown" do
      changeset =
        Trigger.reactive_changeset(%Trigger{}, Map.put(reactive_attrs(), :cooldown_hours, 0))

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :cooldown_hours)
    end

    test "rejects schedule fields" do
      changeset =
        Trigger.reactive_changeset(
          %Trigger{},
          Map.merge(reactive_attrs(), %{
            scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
            schedule_type: "once"
          })
        )

      refute changeset.valid?
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :scheduled_at)
      assert Map.has_key?(errors, :schedule_type)
    end

    test "a later status update keeps the reactive rules" do
      trigger =
        %Trigger{}
        |> Trigger.reactive_changeset(reactive_attrs())
        |> Ecto.Changeset.apply_changes()

      assert Trigger.changeset(trigger, %{status: "paused_by_crisis"}).valid?
    end
  end

  defp active_attrs do
    Map.merge(@ids, %{
      instruction: "cipher",
      scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      timezone: "America/Santiago",
      schedule_type: "once"
    })
  end

  defp reactive_attrs do
    Map.merge(@ids, %{instruction: "cipher", condition: "cipher", cooldown_hours: 24})
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
