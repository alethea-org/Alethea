defmodule Alethea.Alerts.CrisisMonitorTest do
  use ExUnit.Case, async: true
  alias Alethea.Alerts.CrisisMonitor

  describe "detect/1" do
    test "retorna :safe para conversaciones cotidianas" do
      assert CrisisMonitor.detect("Hola, ¿cómo estás?") == :safe
      assert CrisisMonitor.detect("Hoy tuve un buen día en el trabajo.") == :safe
      assert CrisisMonitor.detect("Me siento un poco cansado, pero bien.") == :safe
    end

    test "retorna :safe para texto vacío o nil" do
      assert CrisisMonitor.detect("") == :safe
      assert CrisisMonitor.detect(nil) == :safe
      assert CrisisMonitor.detect("   ") == :safe
    end

    test "detecta nivel :immediate (emergencia inminente)" do
      assert {:crisis, :immediate, triggers} = CrisisMonitor.detect("Me voy a matar hoy mismo.")
      assert "me voy a matar" in triggers

      assert {:crisis, :immediate, triggers} =
               CrisisMonitor.detect("Ya lo decidí, voy a suicidarme.")

      assert "voy a suicidarme" in triggers
      assert "ya (?:lo|la) decid[ií]" in triggers
    end

    test "detecta nivel :high (ideación activa o plan)" do
      assert {:crisis, :high, triggers} =
               CrisisMonitor.detect("No quiero vivir más, ya no aguanto.")

      assert "no quiero (?:vivir|seguir)" in triggers

      assert {:crisis, :high, triggers} =
               CrisisMonitor.detect("Pienso en el suicidio todo el tiempo.")

      assert "pienso en (?:el suicidio|hacerme da[ñn]o)" in triggers
    end

    test "detecta nivel :low (ideación pasiva)" do
      assert {:crisis, :low, triggers} =
               CrisisMonitor.detect("A veces pienso que sería mejor no estar.")

      assert "a veces pienso que ser[ií]a mejor no estar" in triggers

      assert {:crisis, :low, triggers} = CrisisMonitor.detect("Estoy harto de todo.")
      assert "est[oá]y harto de (?:todo|vivir)" in triggers
    end

    test "prioriza la mayor severidad cuando hay múltiples matches" do
      # Contiene patrones de :low ("harto de vivir") y :high ("quiero morir")
      # Debe retornar :high
      assert {:crisis, :high, triggers} =
               CrisisMonitor.detect("Estoy harto de vivir, quiero morir.")

      assert "quiero morir" in triggers
    end

    test "es case-insensitive y maneja tildes (gracias a flag /u)" do
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("ME VOY A MATAR")
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Ya lo decidi")
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Ya lo decidió")
    end
  end
end
