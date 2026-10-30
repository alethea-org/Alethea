defmodule Alethea.Accounts.PatientTimezoneTest do
  @moduledoc """
  Tests for `Alethea.Accounts.PatientTimezone` domain function (S4).
  """

  use ExUnit.Case, async: true

  alias Alethea.Accounts.Patient
  alias Alethea.Accounts.PatientTimezone

  describe "convert_to_utc/3" do
    test "converts local date and time in patient's timezone to UTC" do
      patient = %Patient{timezone: "America/Argentina/Buenos_Aires"}
      date = ~D[2024-05-20]
      time = ~T[16:00:00]

      assert {:ok, utc_dt} = PatientTimezone.convert_to_utc(patient, date, time)
      assert utc_dt == ~U[2024-05-20 19:00:00Z]
    end

    test "converts UTC patient local date and time directly" do
      patient = %Patient{timezone: "Etc/UTC"}
      date = ~D[2024-05-20]
      time = ~T[16:00:00]

      assert {:ok, utc_dt} = PatientTimezone.convert_to_utc(patient, date, time)
      assert utc_dt == ~U[2024-05-20 16:00:00Z]
    end

    test "preserves explicit {:gap, utc_dt1, utc_dt2} for patient during spring forward" do
      patient = %Patient{timezone: "America/New_York"}
      gap_date = ~D[2024-03-10]
      gap_time = ~T[02:15:00]

      assert {:gap, utc_dt1, utc_dt2} =
               PatientTimezone.convert_to_utc(patient, gap_date, gap_time)

      assert utc_dt1.time_zone == "Etc/UTC"
      assert utc_dt2.time_zone == "Etc/UTC"
      assert utc_dt1 == ~U[2024-03-10 06:59:59.999999Z]
      assert utc_dt2 == ~U[2024-03-10 07:00:00Z]
    end

    test "preserves explicit {:ambiguous, utc_dt1, utc_dt2} for patient during fall back" do
      patient = %Patient{timezone: "America/New_York"}
      ambiguous_date = ~D[2024-11-03]
      ambiguous_time = ~T[01:15:00]

      assert {:ambiguous, utc_dt1, utc_dt2} =
               PatientTimezone.convert_to_utc(patient, ambiguous_date, ambiguous_time)

      assert utc_dt1.time_zone == "Etc/UTC"
      assert utc_dt2.time_zone == "Etc/UTC"
      assert utc_dt1 == ~U[2024-11-03 05:15:00Z]
      assert utc_dt2 == ~U[2024-11-03 06:15:00Z]
    end

    test "returns {:error, :time_zone_not_found} when patient has invalid timezone" do
      patient = %Patient{timezone: "Not/Real"}

      assert {:error, :time_zone_not_found} =
               PatientTimezone.convert_to_utc(patient, ~D[2024-01-01], ~T[12:00:00])
    end
  end
end
