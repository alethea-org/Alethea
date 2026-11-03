defmodule Alethea.Triggers.ScheduleTest do
  use ExUnit.Case, async: true

  alias Alethea.Triggers.Schedule

  describe "next_occurrence/2 — daily" do
    test "schedules for next calendar day at same local time" do
      # In America/Santiago (standard time UTC-4 in July)
      trigger = %{
        schedule_type: "daily",
        time: ~T[15:30:00],
        weekdays: nil,
        end_date: nil,
        timezone: "America/Santiago"
      }

      # Fired on 2026-07-10 at 19:30:00Z (which is 15:30:00 in Santiago)
      fired_at = ~U[2026-07-10 19:30:00Z]

      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      assert next_dt == ~U[2026-07-11 19:30:00Z]
    end

    test "respects end_date: fires on end_date, stops after end_date" do
      trigger = %{
        schedule_type: "daily",
        time: ~T[15:30:00],
        weekdays: nil,
        end_date: ~D[2026-07-11],
        timezone: "America/Santiago"
      }

      fired_at_10 = ~U[2026-07-10 19:30:00Z]

      # Next is on 2026-07-11, which equals end_date -> allowed
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at_10)
      assert next_dt == ~U[2026-07-11 19:30:00Z]

      # Firing on 2026-07-11: next would be 2026-07-12 (> end_date) -> :none
      assert :none = Schedule.next_occurrence(trigger, next_dt)
    end

    test "adjusts UTC instant across DST transition (September Santiago spring forward UTC-4 -> UTC-3)" do
      trigger = %{
        schedule_type: "daily",
        time: ~T[15:30:00],
        weekdays: nil,
        end_date: nil,
        timezone: "America/Santiago"
      }

      # In Santiago, DST spring forward in 2026 occurs on Sunday 2026-09-06 at 00:00 (clocks jump to 01:00, UTC-4 -> UTC-3)
      # On Saturday 2026-09-05 (UTC-4): 15:30 local is 19:30 UTC
      fired_at = ~U[2026-09-05 19:30:00Z]

      # Next is Sunday 2026-09-06 (after DST change, UTC-3): 15:30 local is 18:30 UTC
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      assert next_dt == ~U[2026-09-06 18:30:00Z]

      # Local time in America/Santiago for next_dt must be exactly 15:30:00
      {:ok, local_dt} = DateTime.shift_zone(next_dt, "America/Santiago", Tz.TimeZoneDatabase)
      assert DateTime.to_time(local_dt) == ~T[15:30:00]
    end

    test "handles DST spring forward gap gracefully (e.g. time falling inside the skipped hour)" do
      trigger = %{
        schedule_type: "daily",
        time: ~T[00:30:00],
        weekdays: nil,
        end_date: nil,
        timezone: "America/Santiago"
      }

      # Fired on 2026-09-05 at 04:30:00Z (00:30 local)
      fired_at = ~U[2026-09-05 04:30:00Z]

      # On 2026-09-06, 00:30 local is in the gap (00:00 jumped to 01:00)
      # Schedule resolves to valid post-gap instant
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      {:ok, local_dt} = DateTime.shift_zone(next_dt, "America/Santiago", Tz.TimeZoneDatabase)
      assert DateTime.to_date(local_dt) == ~D[2026-09-06]
    end

    test "handles DST fall back ambiguity gracefully (e.g. repeated hour in April)" do
      trigger = %{
        schedule_type: "daily",
        time: ~T[23:30:00],
        weekdays: nil,
        end_date: nil,
        timezone: "America/Santiago"
      }

      # Fired on 2026-04-03 at 02:30:00Z (23:30 local on April 2)
      fired_at = ~U[2026-04-03 02:30:00Z]

      # On 2026-04-04 at 23:30 local, it is in the ambiguous window before midnight jump
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      {:ok, local_dt} = DateTime.shift_zone(next_dt, "America/Santiago", Tz.TimeZoneDatabase)
      assert DateTime.to_time(local_dt) == ~T[23:30:00]
    end
  end

  describe "next_occurrence/2 — weekly" do
    test "schedules for next selected weekday in same week" do
      # Mon (1) and Wed (3)
      trigger = %{
        schedule_type: "weekly",
        time: ~T[10:00:00],
        weekdays: [1, 3],
        end_date: nil,
        timezone: "America/Santiago"
      }

      # Fired on Monday 2026-07-06 at 14:00:00Z (10:00 local in Santiago)
      fired_at = ~U[2026-07-06 14:00:00Z]

      # Next should be Wednesday 2026-07-08 at 14:00:00Z
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      assert next_dt == ~U[2026-07-08 14:00:00Z]
    end

    test "wraps around to next week from last selected day" do
      # Mon (1) and Wed (3)
      trigger = %{
        schedule_type: "weekly",
        time: ~T[10:00:00],
        weekdays: [1, 3],
        end_date: nil,
        timezone: "America/Santiago"
      }

      # Fired on Wednesday 2026-07-08 at 14:00:00Z
      fired_at = ~U[2026-07-08 14:00:00Z]

      # Next should wrap to next Monday 2026-07-13 at 14:00:00Z
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      assert next_dt == ~U[2026-07-13 14:00:00Z]
    end

    test "respects end_date for weekly schedule" do
      trigger = %{
        schedule_type: "weekly",
        time: ~T[10:00:00],
        weekdays: [1, 3],
        end_date: ~D[2026-07-08],
        timezone: "America/Santiago"
      }

      fired_at = ~U[2026-07-06 14:00:00Z]

      # Next is 2026-07-08 (Wednesday), which equals end_date -> allowed
      assert {:ok, next_dt} = Schedule.next_occurrence(trigger, fired_at)
      assert next_dt == ~U[2026-07-08 14:00:00Z]

      # After 2026-07-08, next would be 2026-07-13 (> end_date) -> :none
      assert :none = Schedule.next_occurrence(trigger, next_dt)
    end
  end

  describe "next_occurrence/2 — once" do
    test "returns :none for once trigger" do
      trigger = %{
        schedule_type: "once",
        time: nil,
        weekdays: nil,
        end_date: nil,
        timezone: "America/Santiago"
      }

      assert :none = Schedule.next_occurrence(trigger, ~U[2026-07-10 15:00:00Z])
    end
  end

  describe "initial_occurrence/3" do
    test "daily initial occurrence chooses today if time has not passed" do
      # Patient in America/Santiago
      patient = %{timezone: "America/Santiago"}
      # Reference instant at 12:00 local time
      ref = ~U[2026-07-10 16:00:00Z]
      # Scheduled for 15:30 today (which is in the future relative to 12:00)
      assert {:ok, result} =
               Schedule.initial_occurrence(
                 patient,
                 "daily",
                 %{time: ~T[15:30:00], end_date: nil},
                 ref
               )

      assert result.scheduled_at == ~U[2026-07-10 19:30:00Z]
    end

    test "daily initial occurrence chooses tomorrow if time has already passed today" do
      patient = %{timezone: "America/Santiago"}
      # Reference instant at 16:00 local time
      ref = ~U[2026-07-10 20:00:00Z]
      # Scheduled for 10:00 (which passed today at 10:00)
      assert {:ok, result} =
               Schedule.initial_occurrence(
                 patient,
                 "daily",
                 %{time: ~T[10:00:00], end_date: nil},
                 ref
               )

      # Schedules for tomorrow (2026-07-11) at 10:00 local (14:00Z)
      assert result.scheduled_at == ~U[2026-07-11 14:00:00Z]
    end

    test "rejects end_date before initial occurrence" do
      patient = %{timezone: "America/Santiago"}
      ref = ~U[2026-07-10 20:00:00Z]

      # Time passed today, so initial occurrence is 2026-07-11.
      # Setting end_date to 2026-07-10 must fail.
      assert {:error, {:invalid_end_date, _msg}} =
               Schedule.initial_occurrence(
                 patient,
                 "daily",
                 %{time: ~T[10:00:00], end_date: ~D[2026-07-10]},
                 ref
               )
    end

    test "weekly initial occurrence selects next matching weekday" do
      patient = %{timezone: "America/Santiago"}
      # Friday 2026-07-10 12:00 local
      ref = ~U[2026-07-10 16:00:00Z]

      # Weekdays: Monday (1) and Wednesday (3)
      assert {:ok, result} =
               Schedule.initial_occurrence(
                 patient,
                 "weekly",
                 %{time: ~T[10:00:00], weekdays: [1, 3], end_date: nil},
                 ref
               )

      # Next is Monday 2026-07-13 14:00Z
      assert result.scheduled_at == ~U[2026-07-13 14:00:00Z]
    end

    test "weekly rejects empty weekdays" do
      patient = %{timezone: "America/Santiago"}
      ref = ~U[2026-07-10 16:00:00Z]

      assert {:error, {:empty_weekdays, _msg}} =
               Schedule.initial_occurrence(
                 patient,
                 "weekly",
                 %{time: ~T[10:00:00], weekdays: [], end_date: nil},
                 ref
               )
    end
  end
end
