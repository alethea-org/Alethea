defmodule Alethea.Accounts.Timezone do
  @moduledoc """
  Timezone validation and explicit conversion utilities (Issue #439, S1-S6).
  Uses `Tz.TimeZoneDatabase` directly with no global calendar mutation.
  """

  import Ecto.Changeset

  @default_database Tz.TimeZoneDatabase

  @doc """
  Checks if a timezone identifier is a valid IANA timezone in Tz database.
  """
  @spec valid?(term()) :: boolean()
  def valid?(timezone) when is_binary(timezone) and byte_size(timezone) > 0 do
    match?(
      {:ok, _},
      @default_database.time_zone_period_from_utc_iso_days({0, {0, 86_400_000_000}}, timezone)
    )
  end

  def valid?(_), do: false

  @doc """
  Changeset validation helper for IANA timezone fields.
  """
  @spec validate_timezone(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_timezone(changeset, field \\ :timezone) do
    changeset
    |> validate_required([field])
    |> validate_change(field, fn ^field, value ->
      if valid?(value) do
        []
      else
        [{field, "is not a valid IANA time zone"}]
      end
    end)
  end

  @doc """
  Converts a wall date and time in the given IANA timezone to UTC.
  Preserves explicit `{:ambiguous, ...}` and `{:gap, ...}` outcomes,
  with all returned instants converted to UTC DateTimes.
  """
  @spec convert_to_utc(String.t(), Date.t(), Time.t()) ::
          {:ok, DateTime.t()}
          | {:ambiguous, DateTime.t(), DateTime.t()}
          | {:gap, DateTime.t(), DateTime.t()}
          | {:error, term()}
  def convert_to_utc(timezone, %Date{} = date, %Time{} = time) when is_binary(timezone) do
    case DateTime.new(date, time, timezone, @default_database) do
      {:ok, dt} ->
        shift_to_utc(dt)

      {:ambiguous, dt1, dt2} ->
        with {:ok, utc1} <- shift_to_utc(dt1),
             {:ok, utc2} <- shift_to_utc(dt2) do
          {:ambiguous, utc1, utc2}
        end

      {:gap, dt1, dt2} ->
        with {:ok, utc1} <- shift_to_utc(dt1),
             {:ok, utc2} <- shift_to_utc(dt2) do
          {:gap, utc1, utc2}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def convert_to_utc(_timezone, _date, _time), do: {:error, :invalid_arguments}

  defp shift_to_utc(%DateTime{} = dt) do
    DateTime.shift_zone(dt, "Etc/UTC", @default_database)
  end
end
