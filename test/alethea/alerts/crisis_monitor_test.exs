defmodule Alethea.Alerts.CrisisMonitorTest do
  use ExUnit.Case, async: true

  alias Alethea.Alerts.CrisisMonitor

  setup do
    old_patterns = Application.get_env(:alethea, :crisis_patterns)

    patterns = %{
      immediate: [~r/me voy a matar/iu, ~r/voy a suicidarme/iu],
      high: [~r/quiero morir/iu, ~r/no quiero (?:vivir|seguir)/iu],
      low: [~r/a veces pienso que ser[ií]a mejor no estar/iu]
    }

    Application.put_env(:alethea, :crisis_patterns, patterns)

    on_exit(fn ->
      if old_patterns == nil do
        Application.delete_env(:alethea, :crisis_patterns)
      else
        Application.put_env(:alethea, :crisis_patterns, old_patterns)
      end
    end)

    :ok
  end

  describe "detect/1" do
    test "detecta crisis inmediata y prioriza inmediata sobre otras severidades" do
      assert {:crisis, :immediate, triggers} = CrisisMonitor.detect("Ya lo decidí, me voy a matar")
      assert "me voy a matar" in triggers
    end

    test "detecta crisis de nivel high" do
      assert {:crisis, :high, triggers} = CrisisMonitor.detect("No quiero seguir viviendo")
      assert "no quiero (?:vivir|seguir)" in triggers
    end

    test "detecta crisis de nivel low" do
      assert {:crisis, :low, triggers} = CrisisMonitor.detect("A veces pienso que sería mejor no estar")
      assert "a veces pienso que ser[ií]a mejor no estar" in triggers
    end

    test "detecta múltiples triggers del mismo nivel" do
      assert {:crisis, :high, triggers} = CrisisMonitor.detect("Quiero morir y no quiero seguir")
      assert "quiero morir" in triggers
      assert "no quiero (?:vivir|seguir)" in triggers
    end

    test "texto cotidiano devuelve safe" do
      assert :safe = CrisisMonitor.detect("Hoy fui al supermercado y compré pan")
    end

    test "texto vacío devuelve safe" do
      assert :safe = CrisisMonitor.detect("")
    end

    test "emociones intensas sin riesgo devuelve safe" do
      assert :safe = CrisisMonitor.detect("Estoy muy triste y cansado")
    end
  end
end
