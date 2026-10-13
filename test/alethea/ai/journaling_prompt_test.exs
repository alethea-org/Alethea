defmodule Alethea.AI.JournalingPromptTest do
  @moduledoc """
  Contract tests for the journaling instructions (#392, #393).

  What the model does with these instructions cannot be tested without
  a live model, so the instructions themselves are the observable
  contract: each rule the issue requires must be stated, and every
  example reply must itself obey the rules it illustrates.
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.{ClinicalSafetyPatterns, JournalingOutputGuard, JournalingPrompt}
  alias Alethea.Telegram.TopicExploration

  defp instructions(mode \\ :open),
    do: ClinicalSafetyPatterns.normalize(JournalingPrompt.system_prompt(mode))

  defp heading_list(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "# "))
  end

  describe "system_prompt/0 — structure" do
    test "is organized in explicit sections" do
      assert heading_list(JournalingPrompt.system_prompt()) == [
               "# Rol",
               "# Tono",
               "# Forma de cada respuesta",
               "# Seguir el tema actual",
               "# Marcador de situación",
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

  # #393: both variants are static compile-time attributes selected by
  # `system_prompt/1`; `system_prompt/0` is `system_prompt(:open)`, so
  # every caller that does not pass a mode (every pre-#393 test) keeps
  # working unchanged.
  describe "system_prompt/1 — :open vs :closing" do
    test "system_prompt/0 is the :open variant" do
      assert JournalingPrompt.system_prompt() == JournalingPrompt.system_prompt(:open)
    end

    test ":open adds the topic and marker sections, but not the closing-only one" do
      assert heading_list(JournalingPrompt.system_prompt(:open)) == [
               "# Rol",
               "# Tono",
               "# Forma de cada respuesta",
               "# Seguir el tema actual",
               "# Marcador de situación",
               "# Cuando la conversación se sale del registro",
               "# Prohibido siempre",
               "# Ejemplos"
             ]
    end

    test ":closing adds one more heading: the closing-only section" do
      assert heading_list(JournalingPrompt.system_prompt(:closing)) == [
               "# Rol",
               "# Tono",
               "# Forma de cada respuesta",
               "# Seguir el tema actual",
               "# Marcador de situación",
               "# Cierre de la exploración",
               "# Cuando la conversación se sale del registro",
               "# Prohibido siempre",
               "# Ejemplos"
             ]
    end

    test "the closing-only section appears only in :closing" do
      refute JournalingPrompt.system_prompt(:open) =~ "# Cierre de la exploración"
      assert JournalingPrompt.system_prompt(:closing) =~ "# Cierre de la exploración"
    end

    test "both variants are static and carry the marker-output instruction" do
      for mode <- [:open, :closing] do
        assert JournalingPrompt.system_prompt(mode) == JournalingPrompt.system_prompt(mode)
        assert JournalingPrompt.system_prompt(mode) =~ "<<NUEVO>>"
        assert JournalingPrompt.system_prompt(mode) =~ "<<SIGUE>>"
      end
    end

    test ":closing still states the ordinary one-question rule for a brand-new situation" do
      assert instructions(:closing) =~ "como maximo una pregunta"
    end
  end

  describe "system_prompt/1 — follow-the-latest-topic rule" do
    test "states following the latest topic, no revival, and acknowledge-then-ask-latest" do
      for mode <- [:open, :closing] do
        text = instructions(mode)

        assert text =~ "sigue el tema mas reciente"
        assert text =~ "no revivas"
        assert text =~ "pregunta solo por la ultima"
        assert text =~ "como maximo tres"
      end
    end
  end

  describe "examples/0" do
    test "covers ordinary journaling and every boundary situation" do
      assert Enum.map(JournalingPrompt.examples(), & &1.situation) == [
               :journaling,
               :follow_up,
               :multi_topic,
               :unrelated_request,
               :repeated_unrelated_request,
               :practical_advice,
               :clinical_information,
               :medication,
               :ai_identity
             ]
    end

    test "every example appears in the instructions with explicit speakers and its marker" do
      for example <- JournalingPrompt.examples() do
        assert JournalingPrompt.system_prompt() =~
                 "Paciente: #{example.patient}\nAlethea: #{example.marker} #{example.alethea}"
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

  # #393: every example gains a `marker` field and the two new examples
  # (`:follow_up`, `:multi_topic`) must themselves pass
  # `TopicExploration.parse_marker/1` and `JournalingOutputGuard.check/1`
  # the same way real model output would.
  describe "examples/0 — #393 marker protocol" do
    test "every example carries one of the two markers from markers/0" do
      markers = JournalingPrompt.markers()

      for example <- JournalingPrompt.examples() do
        assert example.marker in [markers.new, markers.same]
      end
    end

    test "the follow-up example signals the same situation, with a stripped single question" do
      example = Enum.find(JournalingPrompt.examples(), &(&1.situation == :follow_up))

      assert example.marker == JournalingPrompt.markers().same

      assert {new_situation, stripped} =
               TopicExploration.parse_marker("#{example.marker} #{example.alethea}")

      refute new_situation
      assert stripped == example.alethea
      assert JournalingOutputGuard.check(example.alethea) == :ok
      assert example.alethea |> String.graphemes() |> Enum.count(&(&1 == "?")) == 1
    end

    test "the multi-topic example signals a new situation, acknowledges both topics once, and asks only about the latest" do
      example = Enum.find(JournalingPrompt.examples(), &(&1.situation == :multi_topic))

      assert example.marker == JournalingPrompt.markers().new
      assert example.patient =~ "trabajo"
      assert example.patient =~ "pareja"

      assert {new_situation, stripped} =
               TopicExploration.parse_marker("#{example.marker} #{example.alethea}")

      assert new_situation
      assert stripped == example.alethea
      assert JournalingOutputGuard.check(example.alethea) == :ok
      assert example.alethea |> String.graphemes() |> Enum.count(&(&1 == "?")) == 1
    end
  end

  describe "markers/0" do
    test "exposes the new-situation and same-situation markers" do
      assert JournalingPrompt.markers() == %{new: "<<NUEVO>>", same: "<<SIGUE>>"}
    end
  end
end
