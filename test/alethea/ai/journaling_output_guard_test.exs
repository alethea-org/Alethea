defmodule Alethea.AI.JournalingOutputGuardTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.JournalingOutputGuard

  describe "check/1" do
    test "allows an acknowledgement followed by an exploratory question" do
      assert JournalingOutputGuard.check(
               "Gracias por contarlo. ¿Qué fue lo más difícil de ese momento?"
             ) == :ok
    end

    test "allows redirecting the patient to their therapist without clinical wording" do
      assert JournalingOutputGuard.check(
               "Eso es algo para conversar con tu terapeuta. ¿Qué te gustaría registrar hoy?"
             ) == :ok
    end

    test "blocks diagnostic language" do
      for reply <- [
            "Parece un trastorno de ansiedad.",
            "Eso es un diagnóstico frecuente.",
            "Cumple criterios de depresión.",
            "Es un cuadro clínico conocido.",
            "Sufre de insomnio crónico."
          ] do
        assert JournalingOutputGuard.check(reply) == {:blocked, :diagnostic}, reply
      end
    end

    test "blocks prescriptive language" do
      for reply <- [
            "Te recomiendo descansar más.",
            "Deberías tomar algo para dormir.",
            "Sería bueno retomar la medicación.",
            "Un tratamiento podría ayudarte.",
            "Hay que iniciar un proceso distinto."
          ] do
        assert JournalingOutputGuard.check(reply) == {:blocked, :prescriptive}, reply
      end
    end

    test "ignores case, accents and irregular whitespace" do
      assert JournalingOutputGuard.check("ESO  ES UN\nDIAGNÓSTICO") == {:blocked, :diagnostic}
      assert JournalingOutputGuard.check("deberias   tomar aire") == {:blocked, :prescriptive}
    end

    test "reports diagnostic language first when both kinds are present" do
      assert JournalingOutputGuard.check("Es un trastorno; te recomiendo tratamiento.") ==
               {:blocked, :diagnostic}
    end
  end
end
