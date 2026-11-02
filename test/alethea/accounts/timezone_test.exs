defmodule Alethea.Accounts.TimezoneTest do
  @moduledoc """
  Unit tests for `Alethea.Accounts.Timezone` (Issue #439, S1-S6).
  Verifies IANA timezone validation, local-to-UTC conversion, offsets,
  DST gap and ambiguous transitions with explicit UTC instants.
  """

  use ExUnit.Case, async: true

  alias Alethea.Accounts.Timezone

  describe "valid?/1" do
    test "accepts valid IANA timezones" do
      assert Timezone.valid?("Etc/UTC")
      assert Timezone.valid?("America/Argentina/Buenos_Aires")
      assert Timezone.valid?("Europe/Madrid")
      assert Timezone.valid?("America/New_York")
    end

    test "rejects invalid or blank timezone strings" do
      refute Timezone.valid?("Invalid/Zone")
      refute Timezone.valid?("UTC+3")
      refute Timezone.valid?("")
      refute Timezone.valid?(nil)
      refute Timezone.valid?(123)
    end
  end

  describe "validate_timezone/2 (changeset helper)" do
    test "validates valid IANA timezone in changeset" do
      changeset =
        timezone_changeset(%{timezone: "America/Argentina/Buenos_Aires"})

      assert changeset.valid?
    end

    test "adds changeset error for invalid IANA timezone" do
      changeset = timezone_changeset(%{timezone: "Invalid/Zone"})
      refute changeset.valid?
      assert %{timezone: ["is not a valid IANA time zone"]} = errors_on(changeset)
    end

    test "adds changeset error when timezone is empty or blank" do
      changeset = timezone_changeset(%{timezone: ""})
      refute changeset.valid?
      assert %{timezone: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "convert_to_utc/3" do
    test "converts UTC wall time directly to UTC DateTime" do
      date = ~D[2024-06-15]
      time = ~T[14:30:00]

      assert {:ok, utc_dt} = Timezone.convert_to_utc("Etc/UTC", date, time)
      assert utc_dt == ~U[2024-06-15 14:30:00Z]
    end

    test "converts local time in non-UTC timezone with constant offset" do
      # America/Argentina/Buenos_Aires is UTC-3 year-round
      date = ~D[2024-01-10]
      time = ~T[10:00:00]

      assert {:ok, utc_dt} = Timezone.convert_to_utc("America/Argentina/Buenos_Aires", date, time)
      # 10:00 in UTC-3 is 13:00 UTC
      assert utc_dt == ~U[2024-01-10 13:00:00Z]
    end

    test "respects winter standard time vs summer daylight saving time offsets" do
      # Europe/Madrid:
      # Winter (standard time, UTC+1): 2024-01-15 12:00 local -> 11:00 UTC
      # Summer (daylight saving, UTC+2): 2024-07-15 12:00 local -> 10:00 UTC
      winter_date = ~D[2024-01-15]
      summer_date = ~D[2024-07-15]
      time = ~T[12:00:00]

      assert {:ok, winter_utc} = Timezone.convert_to_utc("Europe/Madrid", winter_date, time)
      assert winter_utc == ~U[2024-01-15 11:00:00Z]

      assert {:ok, summer_utc} = Timezone.convert_to_utc("Europe/Madrid", summer_date, time)
      assert summer_utc == ~U[2024-07-15 10:00:00Z]
    end

    test "DST gap (spring forward) returns explicit {:gap, utc_dt1, utc_dt2} with UTC instants" do
      # America/New_York on 2024-03-10: 02:00 -> 03:00 clock skip
      # 02:30:00 does not exist locally
      gap_date = ~D[2024-03-10]
      gap_time = ~T[02:30:00]

      assert {:gap, utc_dt1, utc_dt2} =
               Timezone.convert_to_utc("America/New_York", gap_date, gap_time)

      assert utc_dt1.time_zone == "Etc/UTC"
      assert utc_dt2.time_zone == "Etc/UTC"
      assert utc_dt1 == ~U[2024-03-10 06:59:59.999999Z]
      assert utc_dt2 == ~U[2024-03-10 07:00:00Z]
    end

    test "DST ambiguous overlap (fall back) returns explicit {:ambiguous, utc_dt1, utc_dt2} with UTC instants" do
      # America/New_York on 2024-11-03: 02:00 -> 01:00 clock repeat
      # 01:30:00 occurs twice: first in EDT (UTC-4), then in EST (UTC-5)
      ambiguous_date = ~D[2024-11-03]
      ambiguous_time = ~T[01:30:00]

      assert {:ambiguous, utc_dt1, utc_dt2} =
               Timezone.convert_to_utc("America/New_York", ambiguous_date, ambiguous_time)

      assert utc_dt1.time_zone == "Etc/UTC"
      assert utc_dt2.time_zone == "Etc/UTC"
      assert utc_dt1 == ~U[2024-11-03 05:30:00Z]
      assert utc_dt2 == ~U[2024-11-03 06:30:00Z]
    end

    test "returns {:error, :time_zone_not_found} for invalid timezone" do
      assert {:error, :time_zone_not_found} =
               Timezone.convert_to_utc("Invalid/Zone", ~D[2024-01-01], ~T[12:00:00])
    end
  end

  defp timezone_changeset(attrs) do
    {%{}, %{timezone: :string}}
    |> Ecto.Changeset.cast(attrs, [:timezone])
    |> Timezone.validate_timezone(:timezone)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
