defmodule Alethea.Alerts.CrisisMonitor do
  @moduledoc """
  Detector puro de crisis basado en patrones de texto configurables.

  Este módulo no tiene efectos secundarios y solo devuelve el estado de riesgo
  para que el pipeline pueda decidir si debe continuar o cortocircuitar.
  """

  @type severity :: :immediate | :high | :low

  @spec detect(String.t() | nil) :: :safe | {:crisis, severity(), [String.t()]}
  def detect(nil), do: :safe

  def detect(text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      :safe
    else
      patterns_by_severity()
      |> Enum.reduce_while(:safe, fn {severity, patterns}, _acc ->
        triggers = matching_triggers(text, patterns)

        if triggers == [] do
          {:cont, :safe}
        else
          {:halt, {:crisis, severity, triggers}}
        end
      end)
    end
  end

  defp patterns_by_severity do
    Application.get_env(:alethea, :crisis_patterns, default_patterns())
    |> Enum.map(fn {severity, patterns} ->
      {severity, List.wrap(patterns)}
    end)
    |> Enum.sort_by(&pattern_order/1)
  end

  defp matching_triggers(text, patterns) do
    patterns
    |> Enum.filter(&Regex.match?(&1, text))
    |> Enum.map(&Regex.source/1)
  end

  defp pattern_order({:immediate, _}), do: 0
  defp pattern_order({:high, _}), do: 1
  defp pattern_order({:low, _}), do: 2
  defp pattern_order({_other, _}), do: 3

  defp default_patterns do
    %{
      immediate: [
        ~r/me voy a matar/iu,
        ~r/voy a suicidarme/iu,
        ~r/tengo (?:el|un) plan/iu,
        ~r/ya (?:lo|la) decid[ií]/iu
      ],
      high: [
        ~r/quiero morir/iu,
        ~r/no quiero (?:vivir|seguir)/iu,
        ~r/pienso en (?:el suicidio|hacerme da[ñn]o)/iu,
        ~r/me quiero hacer da[ñn]o/iu
      ],
      low: [
        ~r/a veces pienso que ser[ií]a mejor no estar/iu,
        ~r/no tiene sentido (?:seguir|vivir)/iu,
        ~r/est[oá]y harto de (?:todo|vivir)/iu
      ]
    }
  end
end
