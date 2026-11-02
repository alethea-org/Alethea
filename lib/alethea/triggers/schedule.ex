defmodule Alethea.Triggers.Schedule do
  @moduledoc """
  Pure scheduling math and recurrence resolution for active triggers (Issue #441).
  Computes next occurrences across DST changes in the patient's timezone.
  """

  alias Alethea.Accounts.Timezone

  @default_database Tz.TimeZoneDatabase
  @default_timezone "America/Santiago"

  @doc """
  Computes the initial occurrence for a newly created trigger given patient, schedule_type, attrs,
  and an optional reference UTC instant (defaults to DateTime.utc_now()).
  """
  @spec initial_occurrence(map(), String.t(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def initial_occurrence(patient, schedule_type, attrs, ref \\ DateTime.utc_now())

  def initial_occurrence(patient, "once", attrs, ref) do
    timezone = patient_timezone(patient)

    with {:ok, date, time} <- parse_date_and_time(attrs),
         {:ok, scheduled_at} <- convert_once_to_utc(timezone, date, time),
         :ok <- validate_future_instant(scheduled_at, ref) do
      {:ok,
       %{
         schedule_type: "once",
         scheduled_at: scheduled_at,
         date: date,
         time: time,
         weekdays: nil,
         end_date: nil
       }}
    end
  end

  def initial_occurrence(patient, "daily", attrs, ref) do
    timezone = patient_timezone(patient)

    with {:ok, time} <- parse_time(attrs),
         {:ok, end_date} <- parse_end_date(attrs),
         {:ok, local_ref} <- DateTime.shift_zone(ref, timezone, @default_database) do
      today = DateTime.to_date(local_ref)
      now_time = DateTime.to_time(local_ref)

      first_date =
        if Time.compare(time, now_time) == :gt do
          today
        else
          Date.add(today, 1)
        end

      with :ok <- validate_end_date(first_date, end_date),
           {:ok, scheduled_at} <- resolve_utc(first_date, time, timezone) do
        {:ok,
         %{
           schedule_type: "daily",
           scheduled_at: scheduled_at,
           time: time,
           weekdays: nil,
           end_date: end_date
         }}
      end
    end
  end

  def initial_occurrence(patient, "weekly", attrs, ref) do
    timezone = patient_timezone(patient)

    with {:ok, time} <- parse_time(attrs),
         {:ok, weekdays} <- parse_weekdays(attrs),
         {:ok, end_date} <- parse_end_date(attrs),
         {:ok, local_ref} <- DateTime.shift_zone(ref, timezone, @default_database) do
      today = DateTime.to_date(local_ref)
      now_time = DateTime.to_time(local_ref)
      today_dow = Date.day_of_week(today)

      first_date =
        if today_dow in weekdays and Time.compare(time, now_time) == :gt do
          today
        else
          find_next_matching_weekday(today, weekdays)
        end

      with :ok <- validate_end_date(first_date, end_date),
           {:ok, scheduled_at} <- resolve_utc(first_date, time, timezone) do
        {:ok,
         %{
           schedule_type: "weekly",
           scheduled_at: scheduled_at,
           time: time,
           weekdays: weekdays,
           end_date: end_date
         }}
      end
    end
  end

  def initial_occurrence(_patient, invalid_type, _attrs, _ref) do
    {:error, {:invalid_schedule_type, invalid_type}}
  end

  @doc """
  Computes the next occurrence (in UTC) for an active trigger strictly after `from_utc`.
  Returns `{:ok, %DateTime{}}` or `:none` if schedule is one-shot or end_date has been reached.
  """
  @spec next_occurrence(map(), DateTime.t()) :: {:ok, DateTime.t()} | :none | {:error, term()}
  def next_occurrence(%{schedule_type: "once"}, _from_utc), do: :none

  def next_occurrence(
        %{schedule_type: "daily", time: %Time{} = time} = trigger,
        %DateTime{} = from_utc
      ) do
    timezone = trigger_timezone(trigger)

    case DateTime.shift_zone(from_utc, timezone, @default_database) do
      {:ok, local_from} ->
        local_date = DateTime.to_date(local_from)
        next_date = Date.add(local_date, 1)

        end_date = Map.get(trigger, :end_date)

        if reached_end_date?(next_date, end_date) do
          :none
        else
          resolve_utc(next_date, time, timezone)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def next_occurrence(
        %{schedule_type: "weekly", time: %Time{} = time} = trigger,
        %DateTime{} = from_utc
      ) do
    timezone = trigger_timezone(trigger)
    weekdays = Map.get(trigger, :weekdays) || []

    if weekdays == [] do
      :none
    else
      case DateTime.shift_zone(from_utc, timezone, @default_database) do
        {:ok, local_from} ->
          local_date = DateTime.to_date(local_from)
          next_date = find_next_matching_weekday(local_date, weekdays)
          end_date = Map.get(trigger, :end_date)

          if reached_end_date?(next_date, end_date) do
            :none
          else
            resolve_utc(next_date, time, timezone)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def next_occurrence(_trigger, _from_utc), do: :none

  # --- Formatters for UI & Badges ---

  @doc """
  Returns a human-readable badge label for a trigger schedule.
  """
  @spec schedule_badge(map()) :: String.t()
  def schedule_badge(%{schedule_type: "daily"}), do: "Diario"

  def schedule_badge(%{schedule_type: "weekly", weekdays: days})
      when is_list(days) and days != [] do
    formatted =
      days
      |> Enum.sort()
      |> Enum.map(&weekday_short_name/1)
      |> Enum.join(", ")

    "Semanal (#{formatted})"
  end

  def schedule_badge(%{schedule_type: "weekly"}), do: "Semanal"
  def schedule_badge(_trigger), do: "Una sola vez"

  @doc """
  Short Spanish name for an ISO weekday (1..7).
  """
  @spec weekday_short_name(integer()) :: String.t()
  def weekday_short_name(1), do: "Lun"
  def weekday_short_name(2), do: "Mar"
  def weekday_short_name(3), do: "Mié"
  def weekday_short_name(4), do: "Jue"
  def weekday_short_name(5), do: "Vie"
  def weekday_short_name(6), do: "Sáb"
  def weekday_short_name(7), do: "Dom"
  def weekday_short_name(_), do: ""

  # --- Helpers ---

  defp patient_timezone(%{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  defp patient_timezone(_), do: @default_timezone

  defp trigger_timezone(%{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  defp trigger_timezone(_), do: @default_timezone

  defp reached_end_date?(_date, nil), do: false

  defp reached_end_date?(date, %Date{} = end_date) do
    Date.compare(date, end_date) == :gt
  end

  defp validate_end_date(_first_date, nil), do: :ok

  defp validate_end_date(first_date, %Date{} = end_date) do
    if Date.compare(first_date, end_date) == :gt do
      {:error, {:invalid_end_date, "La fecha de fin no puede ser anterior al primer envío."}}
    else
      :ok
    end
  end

  defp validate_future_instant(%DateTime{} = dt, %DateTime{} = ref) do
    if DateTime.compare(dt, ref) == :gt do
      :ok
    else
      {:error, :past_schedule}
    end
  end

  defp find_next_matching_weekday(%Date{} = from_date, weekdays) do
    1..7
    |> Enum.map(&Date.add(from_date, &1))
    |> Enum.find(fn cand -> Date.day_of_week(cand) in weekdays end)
  end

  defp resolve_utc(%Date{} = date, %Time{} = time, timezone) do
    case Timezone.convert_to_utc(timezone, date, time) do
      {:ok, utc} ->
        {:ok, DateTime.truncate(utc, :second)}

      {:gap, _utc1, utc2} ->
        {:ok, DateTime.truncate(utc2, :second)}

      {:ambiguous, utc1, _utc2} ->
        {:ok, DateTime.truncate(utc1, :second)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_once_to_utc(timezone, %Date{} = date, %Time{} = time) do
    case Timezone.convert_to_utc(timezone, date, time) do
      {:ok, utc} ->
        {:ok, DateTime.truncate(utc, :second)}

      {:gap, _dt1, _dt2} ->
        {:error,
         {:gap,
          "La hora ingresada no existe debido al cambio de horario de verano en la zona horaria del paciente."}}

      {:ambiguous, _dt1, _dt2} ->
        {:error,
         {:ambiguous,
          "La hora ingresada es ambigua debido al cambio de horario en la zona horaria del paciente."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_date_and_time(%{date: %Date{} = d, time: %Time{} = t}), do: {:ok, d, t}

  defp parse_date_and_time(attrs) when is_map(attrs) do
    d_val = Map.get(attrs, "date") || Map.get(attrs, :date)
    t_val = Map.get(attrs, "time") || Map.get(attrs, :time)

    with {:ok, date} <- parse_date_val(d_val),
         {:ok, time} <- parse_time_val(t_val) do
      {:ok, date, time}
    else
      _ -> {:error, :invalid_date_time}
    end
  end

  defp parse_time(attrs) when is_map(attrs) do
    t_val = Map.get(attrs, "time") || Map.get(attrs, :time)
    parse_time_val(t_val)
  end

  defp parse_time_val(%Time{} = t), do: {:ok, t}

  defp parse_time_val(str) when is_binary(str) do
    case Time.from_iso8601(str) do
      {:ok, time} ->
        {:ok, time}

      {:error, _} ->
        case String.split(str, ":") do
          [h, m] ->
            with {hh, ""} <- Integer.parse(h),
                 {mm, ""} <- Integer.parse(m),
                 {:ok, time} <- Time.new(hh, mm, 0) do
              {:ok, time}
            else
              _ -> {:error, :invalid_time}
            end

          _ ->
            {:error, :invalid_time}
        end
    end
  end

  defp parse_time_val(_), do: {:error, :invalid_time}

  defp parse_date_val(%Date{} = d), do: {:ok, d}

  defp parse_date_val(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date_val(_), do: {:error, :invalid_date}

  defp parse_end_date(attrs) when is_map(attrs) do
    val = Map.get(attrs, "end_date") || Map.get(attrs, :end_date)

    case val do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %Date{} = d -> {:ok, d}
      str when is_binary(str) -> parse_date_val(str)
      _ -> {:error, :invalid_end_date}
    end
  end

  defp parse_weekdays(attrs) when is_map(attrs) do
    val = Map.get(attrs, "weekdays") || Map.get(attrs, :weekdays)

    case val do
      nil ->
        {:error, {:empty_weekdays, "Debes seleccionar al menos un día de la semana."}}

      [] ->
        {:error, {:empty_weekdays, "Debes seleccionar al menos un día de la semana."}}

      days when is_list(days) ->
        parsed =
          days
          |> Enum.map(fn
            d when is_integer(d) and d in 1..7 ->
              d

            d when is_binary(d) ->
              case Integer.parse(d) do
                {n, ""} when n in 1..7 -> n
                _ -> nil
              end

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        if parsed == [] do
          {:error, {:empty_weekdays, "Debes seleccionar al menos un día de la semana."}}
        else
          {:ok, parsed}
        end

      _ ->
        {:error, {:empty_weekdays, "Debes seleccionar al menos un día de la semana."}}
    end
  end
end
