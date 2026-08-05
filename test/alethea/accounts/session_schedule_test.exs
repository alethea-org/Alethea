defmodule Alethea.Accounts.SessionScheduleTest do
  @moduledoc """
  Unit tests for `Alethea.Accounts.SessionSchedule.next_datetime/3`
  (telegram-session-reminders, #97, Phase 1).

  Pure module — no DB, no Oban, frozen `from` in every case so the
  computed `DateTime` is deterministic and reproducible.

  Fixture week: 2024-01-01 (Monday) .. 2024-01-07 (Sunday).
    - 2024-01-03 = Wednesday (dow 3)
    - 2024-01-06 = Saturday  (dow 6)
    - 2024-01-08 = Monday    (dow 1, next week)
  """

  use ExUnit.Case, async: true

  alias Alethea.Accounts.SessionSchedule

  describe "next_datetime/3" do
    test "same-week future: target dow is later in the same week than `from`" do
      # Wednesday 10:00 UTC -> next Friday 14:00 UTC (2 days later).
      from = ~U[2024-01-03 10:00:00Z]

      result = SessionSchedule.next_datetime(5, ~T[14:00:00], from)

      assert result == ~U[2024-01-05 14:00:00Z]
    end

    test "same-day, time already passed today -> rolls to next week (+7)" do
      # Wednesday 10:00 UTC, target dow is the SAME Wednesday but at
      # 09:00 (earlier than `from`) -> the slot already passed today,
      # so the next occurrence is 7 days later.
      from = ~U[2024-01-03 10:00:00Z]

      result = SessionSchedule.next_datetime(3, ~T[09:00:00], from)

      assert result == ~U[2024-01-10 09:00:00Z]
    end

    test "same-day, time exactly equal to `from` -> not strictly future, rolls to next week" do
      # The guard uses DateTime.compare(dt, from) == :gt (strict), so
      # an exact match does NOT count as "still ahead" -- it rolls.
      from = ~U[2024-01-03 10:00:00Z]

      result = SessionSchedule.next_datetime(3, ~T[10:00:00], from)

      assert result == ~U[2024-01-10 10:00:00Z]
    end

    test "DOW wrap-around: target dow is earlier in the week number than `from`'s dow" do
      # Saturday (dow 6) -> next Monday (dow 1) wraps across the week
      # boundary via the `+ 7` modulo term, not a negative day delta.
      from = ~U[2024-01-06 08:00:00Z]

      result = SessionSchedule.next_datetime(1, ~T[07:00:00], from)

      assert result == ~U[2024-01-08 07:00:00Z]
    end
  end
end
