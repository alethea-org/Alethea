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
    # Comprehensive crisis detection patterns for Spanish
    # Covers various orthographic variants and colloquial expressions
    # Uses case-insensitive matching with unicode support

    # Immediate crisis - active suicidal intent with plan or decision
    immediate_patterns = [
      # Direct expressions of suicide
      ~r/me voy a matar/iu,
      ~r/voy a suicidarm[e]/iu,
      ~r/me suicidar[e]/iu,
      ~r/voy a terminar con mi vida/iu,
      ~r/me voy a quitar la vida/iu,
      # Plan/intention expressions
      ~r/tengo (?:el|un) plan/iu,
      ~r/ya (?:lo|la) decid[ií]/iu,
      ~r/ya s[eé] c[oó]mo hacerlo/iu,
      ~r/tengo los medios/iu
    ]

    # High crisis - passive suicidal ideation or self-harm thoughts
    high_patterns = [
      # Death/wanting to die
      ~r/quiero morir/iu,
      ~r/me gustar[ií]a estar muerto/iu,
      ~r/ojal[áa] estuviera muerto/iu,
      # Passive suicidal ideation
      ~r/no quiero (?:vivir|seguir|living)/iu,
      ~r/no tengo ganas de vivir/iu,
      ~r/no me importa seguir vivo/iu,
      # Self-harm thoughts (comprehensive variant coverage)
      ~r/pienso en (?:el suicidio|hacerme da[ñn]o|hacerme daã±o)/iu,
      ~r/piens[oa] en hacerme da[ñn]o/iu,
      ~r/me quiero hacer da[ñn]o/iu,
      ~r/quiero hacerme da[ñn]o/iu,
      ~r/piens[oa] en cortarm[e]/iu,
      ~r/piens[oa] en autolesionar/iu,
      # Hopelessness with ideation
      ~r/no tiene sentido nada/iu,
      ~r/todo es in[úu]til/iu
    ]

    # Low crisis - existential distress, passive thoughts
    low_patterns = [
      ~r/a veces pienso que ser[ií]a mejor no estar/iu,
      ~r/qu[e] no tiene sentido (?:seguir|vivir)/iu,
      ~r/estoy harto de (?:todo|vivir)/iu,
      ~r/ya no puedo m[áa]s/iu,
      ~r/nada tiene sentido/iu,
      ~r/para qu[eé] seguir/iu,
      ~r/mi vida no vale nada/iu,
      ~r/me siento in[úu]til/iu,
      ~r/ser[ií]a mejor sin m[ií]/iu,
      # Desperation expressions
      ~r/no s[eé] qu[eé] hacer con mi vida/iu,
      ~r/estoy al limite/iu,
      ~r/ya no m[ae] llega/iu
    ]

    # Combine all severity levels
    patterns = [
      {:immediate, immediate_patterns},
      {:high, high_patterns},
      {:low, low_patterns}
    ]

    # Parse any config override and merge
    config_patterns = Application.get_env(:alethea, :crisis_patterns, [])

    Enum.reduce(config_patterns, patterns, fn {severity, new_patterns}, acc ->
      Enum.map(acc, fn
        {^severity, existing} -> {severity, existing ++ List.wrap(new_patterns)}
        other -> other
      end)
    end)
  end
end
