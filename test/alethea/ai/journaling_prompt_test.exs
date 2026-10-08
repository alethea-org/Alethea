defmodule Alethea.AI.JournalingPromptTest do
  @moduledoc """
  Contract tests for the journaling instructions (#392).

  What the model does with these instructions cannot be tested without
  a live model, so the instructions themselves are the observable
  contract: each rule the issue requires must be stated, and every
  example reply must itself obey the rules it illustrates.
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.{ClinicalSafetyPatterns, JournalingOutputGuard, JournalingPrompt}

  defp instructions, do: ClinicalSafetyPatterns.normalize(JournalingPrompt.system_prompt())

  describe "system_prompt/0 — structure" do
    test "is organized in explicit sections" do
      headings =
        JournalingPrompt.system_prompt()
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.starts_with?(&1, "# "))

      assert headings == [
               "# Rol",
               "# Tono",
               "# Forma de cada respuesta",
               "# Cuando la conversación se sale del registro",
               "# Prohibido siempre",
               "# Ejemplos"
             ]
    end

    test "is static: it carries no slot for patient or clinical data" do
      assert JournalingPrompt.system_prompt() == JournalingPrompt.system_prompt()
      refute JournalingPrompt.system_prompt() =~ "Contexto del paciente"
      refute JournalingPrompt.system_prompt() =~ "Análisis Emocional"
    end
  end

  describe "system_prompt/0 — reply shape and tone" do
    test "asks for a brief acknowledgement before at most one question" do
      assert instructions() =~ "reconocimiento breve"
      assert instructions() =~ "como maximo una pregunta"
    end

    test "sets a single warm-professional tone and short replies that end complete" do
      assert instructions() =~ "calido y profesional"
      assert instructions() =~ "maximo tres oraciones"
      assert instructions() =~ "termina siempre la ultima oracion"
    end
  end

  describe "system_prompt/0 — redirection rules" do
    test "redirects unrelated requests, and repeated ones each time" do
      assert instructions() =~ "pedido ajeno al journaling"
      assert instructions() =~ "si el pedido ajeno se repite"
    end

    test "explores the concern behind a request for practical advice instead of solving it" do
      assert instructions() =~ "no digas que hacer"
      assert instructions() =~ "que es lo que le preocupa"
    end

    test "sends clinical questions to the therapist without confirming or denying anything" do
      for topic <- [
            "diagnosticos",
            "medicacion",
            "analisis de sus emociones",
            "notas de su terapeuta"
          ] do
        assert instructions() =~ topic, topic
      end

      assert instructions() =~ "conversar con su terapeuta"
      assert instructions() =~ "no confirmes ni niegues"
    end

    test "requires an honest answer about being an AI" do
      assert instructions() =~ "eres una inteligencia artificial"
    end
  end

  describe "system_prompt/0 — prohibitions" do
    test "names every prohibited behavior" do
      prohibited_section =
        instructions()
        |> String.split("# prohibido siempre")
        |> Enum.at(1)
        |> String.split("# ejemplos")
        |> hd()

      for prohibition <- [
            "diagnosticar",
            "recetar",
            "interpretar sueños",
            "jerga clinica",
            "sugerir actividades",
            "comparar",
            "opinar sobre las personas"
          ] do
        assert prohibited_section =~ prohibition, prohibition
      end
    end
  end

  describe "examples/0" do
    test "covers ordinary journaling and every boundary situation" do
      assert Enum.map(JournalingPrompt.examples(), & &1.situation) == [
               :journaling,
               :unrelated_request,
               :repeated_unrelated_request,
               :practical_advice,
               :clinical_information,
               :medication,
               :ai_identity
             ]
    end

    test "every example appears in the instructions with explicit speakers" do
      for example <- JournalingPrompt.examples() do
        assert JournalingPrompt.system_prompt() =~
                 "Paciente: #{example.patient}\nAlethea: #{example.alethea}"
      end
    end

    test "every example reply would pass the output guard" do
      for example <- JournalingPrompt.examples() do
        assert JournalingOutputGuard.check(example.alethea) == :ok, example.alethea
      end
    end

    test "every example reply is short, complete, and asks at most one question" do
      for %{alethea: reply} <- JournalingPrompt.examples() do
        assert String.length(reply) <= 200, reply
        assert String.ends_with?(reply, [".", "?"]), reply
        assert reply |> String.graphemes() |> Enum.count(&(&1 == "?")) <= 1, reply
      end
    end

    test "the AI-identity example answers honestly" do
      example = Enum.find(JournalingPrompt.examples(), &(&1.situation == :ai_identity))

      assert example.alethea =~ "inteligencia artificial"
    end

    test "the clinical examples point to the therapist" do
      for situation <- [:clinical_information, :medication] do
        example = Enum.find(JournalingPrompt.examples(), &(&1.situation == situation))

        assert example.alethea =~ "tu terapeuta"
      end
    end
  end
end
