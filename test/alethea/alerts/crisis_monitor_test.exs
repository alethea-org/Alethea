defmodule Alethea.Alerts.CrisisMonitorTest do
  use ExUnit.Case, async: true

  alias Alethea.Alerts.CrisisMonitor

  describe "detect/1" do
    test "returns safe for nil" do
      assert CrisisMonitor.detect(nil) == :safe
    end

    test "returns safe for empty string" do
      assert CrisisMonitor.detect("") == :safe
      assert CrisisMonitor.detect("   ") == :safe
      assert CrisisMonitor.detect("\n\t") == :safe
    end
  end

  describe "immediate crisis detection" do
    test "detects 'me voy a matar'" do
      assert {:crisis, :immediate, triggers} = CrisisMonitor.detect("Me voy a matar")
      assert "me voy a matar" in triggers
    end

    test "detects 'voy a suicidarme'" do
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Voy a suicidarme")
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Me voy a suicidar")
    end

    test "detects plan expressions" do
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Tengo el plan")
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Tengo un plan para hacerlo")
    end

    test "detects 'ya lo decidí'" do
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Ya lo decidí")
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Ya la decidí")
    end

    test "is case insensitive" do
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("ME VOY A MATAR")
      assert {:crisis, :immediate, _} = CrisisMonitor.detect("Me Voy A Suicidarme")
    end
  end

  describe "high crisis detection" do
    test "detects 'quiero morir'" do
      assert {:crisis, :high, _} = CrisisMonitor.detect("Quiero morir")
    end

    test "detects 'no quiero vivir'" do
      assert {:crisis, :high, _} = CrisisMonitor.detect("No quiero vivir más")
      assert {:crisis, :high, _} = CrisisMonitor.detect("No quiero seguir")
    end

    test "detects self-harm thoughts" do
      assert {:crisis, :high, _} = CrisisMonitor.detect("Pienso en hacerme daño")
      assert {:crisis, :high, _} = CrisisMonitor.detect("Me quiero hacer daño")
      assert {:crisis, :high, _} = CrisisMonitor.detect("Quiero hacerme daño")
    end

    test "detects hopelessness" do
      assert {:crisis, :high, _} = CrisisMonitor.detect("No tiene sentido nada")
      assert {:crisis, :high, _} = CrisisMonitor.detect("Todo es inútil")
    end
  end

  describe "low crisis detection" do
    test "detects 'a veces pienso que sería mejor no estar'" do
      assert {:crisis, :low, _} = CrisisMonitor.detect("A veces pienso que sería mejor no estar")
    end

    test "detects 'no tiene sentido seguir'" do
      assert {:crisis, :low, _} = CrisisMonitor.detect("No tiene sentido seguir")
      assert {:crisis, :low, _} = CrisisMonitor.detect("Qué no tiene sentido vivir")
    end

    test "detects desperation expressions" do
      assert {:crisis, :low, _} = CrisisMonitor.detect("Ya no puedo más")
      assert {:crisis, :low, _} = CrisisMonitor.detect("Estoy harto de todo")
      assert {:crisis, :low, _} = CrisisMonitor.detect("No sé qué hacer con mi vida")
    end

    test "detects 'estoy al límite'" do
      assert {:crisis, :low, _} = CrisisMonitor.detect("Estoy al límite")
      assert {:crisis, :low, _} = CrisisMonitor.detect("Ya no me llega")
    end
  end

  describe "safe messages (no false positives)" do
    test "handles normal emotional expressions" do
      safe_messages = [
        "Me siento triste hoy",
        "Estoy un poco down",
        "Fue un día difícil",
        "Me canso fácilmente",
        "A veces estoy enojado",
        "Me siento solo a veces",
        "Me genera ansiedad ir al médico",
        "No dormí bien",
        "Tengo estrés en el trabajo",
        "Me preocupa mi salud"
      ]

      for msg <- safe_messages do
        assert CrisisMonitor.detect(msg) == :safe,
               "False positive for: #{msg}"
      end
    end

    test "handles clinical/medical context" do
      safe_messages = [
        "El médico me dijo que puedo morir si no tomo la medicación",
        "Tengo miedo de morirme",
        "Pensé en la muerte hoy",
        "Mi abuelo murió la semana pasada"
      ]

      # These should NOT trigger crisis - they are clinical/medical context
      for msg <- safe_messages do
        assert CrisisMonitor.detect(msg) == :safe,
               "False positive for clinical context: #{msg}"
      end
    end

    test "handles idiomatic expressions" do
      safe_messages = [
        "Me muero de risa",
        "Estoy muerto de cansancio",
        "Qué pereza vivir así",
        "No puedo con mi vida (cansado)",
        "Me quiero morir de hambre"
      ]

      for msg <- safe_messages do
        assert CrisisMonitor.detect(msg) == :safe,
               "False positive for idiomatic: #{msg}"
      end
    end

    test "handles therapeutic content" do
      safe_messages = [
        "En terapia hablamos sobre la muerte",
        "Exploré mis pensamientos sobre la vida",
        "Hicimos un ejercicio sobre el sentido de la vida"
      ]

      for msg <- safe_messages do
        assert CrisisMonitor.detect(msg) == :safe,
               "False positive for therapeutic: #{msg}"
      end
    end
  end

  describe "severity ordering" do
    test "immediate takes precedence over high" do
      # If text matches both immediate and high patterns, should return immediate
      result = CrisisMonitor.detect("Me voy a matar porque no quiero vivir")

      assert {:crisis, :immediate, _} = result
    end

    test "high takes precedence over low" do
      result = CrisisMonitor.detect("No quiero vivir y a veces pienso que sería mejor no estar")

      assert {:crisis, :high, _} = result
    end
  end

  describe "unicode support" do
    test "handles accented characters" do
      assert {:crisis, :high, _} = CrisisMonitor.detect("No quiero seguir más")
      assert {:crisis, :high, _} = CrisisMonitor.detect("No quiero vivir más")
      assert {:crisis, :low, _} = CrisisMonitor.detect("Qué pereza vivir")
    end

    test "handles ñ and special characters" do
      # These should still work with unicode patterns
      assert CrisisMonitor.detect("Me siento inútil") == :safe
      assert CrisisMonitor.detect("Sería mejor no estar") == :safe
    end
  end
end
