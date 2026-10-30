defmodule Alethea.Accounts.PatientTimezone do
  @moduledoc """
  Patient-scoped timezone conversion domain service (Issue #439, S4).
  Converts local dates and times for a given patient to UTC using their
  configured IANA timezone.
  """

  alias Alethea.Accounts.{Patient, Timezone}

  @doc """
  Converts a patient's local date and time to UTC.
  Preserves explicit `{:ambiguous, ...}` and `{:gap, ...}` outcomes,
  with all returned instants converted to UTC DateTimes.
  """
  @spec convert_to_utc(Patient.t() | map(), Date.t(), Time.t()) ::
          {:ok, DateTime.t()}
          | {:ambiguous, DateTime.t(), DateTime.t()}
          | {:gap, DateTime.t(), DateTime.t()}
          | {:error, term()}
  def convert_to_utc(%{timezone: timezone}, %Date{} = date, %Time{} = time)
      when is_binary(timezone) do
    Timezone.convert_to_utc(timezone, date, time)
  end

  def convert_to_utc(_patient, _date, _time), do: {:error, :invalid_arguments}

  @doc """
  Alias for `convert_to_utc/3`.
  """
  def to_utc(patient, date, time), do: convert_to_utc(patient, date, time)
end
