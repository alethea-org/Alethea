defmodule Alethea.Telegram.TopicExplorationTest do
  # #393 S2 (design §1, §3): the pure marker-tolerance parsing and the
  # question-limit/closing decision table. Nothing calls this module
  # from production code yet (that is S3); these tests exercise
  # `TopicExploration`'s functions directly with plain Elixir data, not
  # through the full worker pipeline.
  use ExUnit.Case, async: true

  alias Alethea.Telegram.{JournalingFallback, TopicExploration}

  describe "parse_marker/1" do
    # Trim lever (task 2.8): every tolerance case shares the same
    # shape — input text in, `{new_situation, stripped_text}` out —
    # table-driven here instead of one test per case.
    for {name, input, expected} <- [
          {"leading marker on its own line", "<<NUEVO>>\n¿Qué sentiste?",
           {true, "¿Qué sentiste?"}},
          {"leading marker followed by text on the same line", "<<SIGUE>> Qué tal con eso.",
           {false, "Qué tal con eso."}},
          {"leading marker, blank line, then the reply", "<<NUEVO>>\n\nGracias por contarlo.",
           {true, "Gracias por contarlo."}},
          {"lowercase marker word", "<<nuevo>>\nHola.", {true, "Hola."}},
          {"marker with internal spacing", "<< NUEVO >>\nHola.", {true, "Hola."}},
          {"marker misplaced mid-text is stripped but not treated as leading",
           "Hola <<NUEVO>> qué tal", {false, "Hola  qué tal"}},
          {"malformed marker word (not NUEVO/SIGUE) is stripped but treated as same-situation",
           "<<OTRO>>\n¿Qué tal?", {false, "¿Qué tal?"}},
          {"unclosed leading fragment left by truncation", "<<NUE deseo contarte algo",
           {false, "deseo contarte algo"}},
          {"missing marker entirely", "¿Qué tal estuvo tu día?",
           {false, "¿Qué tal estuvo tu día?"}},
          {"marker-only text strips to empty", "<<SIGUE>>", {false, ""}}
        ] do
      test "#{name}" do
        assert TopicExploration.parse_marker(unquote(input)) == unquote(expected)
      end
    end
  end

  describe "mode/1" do
    for {name, state, expected} <- [
          {"below the limit", %{questions: 0, closing_invitation_sent: false}, :open},
          {"one below the limit", %{questions: 2, closing_invitation_sent: false}, :open},
          {"at the limit", %{questions: 3, closing_invitation_sent: false}, :closing},
          {"at the limit, invitation already sent",
           %{questions: 3, closing_invitation_sent: true}, :closing}
        ] do
      test "returns #{inspect(expected)} #{name}" do
        assert TopicExploration.mode(unquote(Macro.escape(state))) == unquote(expected)
      end
    end
  end

  describe "enforce/4" do
    @inbound_id "00000000-0000-4000-8000-000000000001"

    # Trim lever (task 2.8): design §3's four-row decision table,
    # table-driven. `reply` is the minimal shape `enforce/4` reads
    # (`:response`); `model_version` starts as `"phi-4-mini"` so the
    # swap-on-substitution case is observable.
    for {name, reply, state, new_situation, expected_response, expected_model_version,
         expected_exploration} <- [
          {"NUEVO with a question resets the count to 1, unsent",
           %{response: "¿Qué pasó?", model_version: "phi-4-mini"},
           %{questions: 3, closing_invitation_sent: true}, true, "¿Qué pasó?", "phi-4-mini",
           %{exploration_questions: 1, closing_invitation_sent: false, new_situation: true}},
          {"NUEVO without a question resets the count to 0, unsent",
           %{response: "Gracias por contarlo.", model_version: "phi-4-mini"},
           %{questions: 3, closing_invitation_sent: true}, true, "Gracias por contarlo.",
           "phi-4-mini",
           %{exploration_questions: 0, closing_invitation_sent: false, new_situation: true}},
          {"SIGUE below the limit with a question increments the count, unchanged response",
           %{response: "¿Y después?", model_version: "phi-4-mini"},
           %{questions: 1, closing_invitation_sent: false}, false, "¿Y después?", "phi-4-mini",
           %{exploration_questions: 2, closing_invitation_sent: false, new_situation: false}},
          {"SIGUE below the limit without a question leaves the count unchanged",
           %{response: "Entiendo.", model_version: "phi-4-mini"},
           %{questions: 1, closing_invitation_sent: false}, false, "Entiendo.", "phi-4-mini",
           %{exploration_questions: 1, closing_invitation_sent: false, new_situation: false}},
          {"SIGUE at the limit, not yet sent, with a question: substituted with the closing invitation",
           %{response: "¿Qué más pasó?", model_version: "phi-4-mini"},
           %{questions: 3, closing_invitation_sent: false}, false, :closing_invitation,
           "journaling-fallback",
           %{exploration_questions: 3, closing_invitation_sent: true, new_situation: false}},
          {"SIGUE at the limit, already sent, with a question: substituted with the acknowledgement",
           %{response: "¿Algo más?", model_version: "phi-4-mini"},
           %{questions: 3, closing_invitation_sent: true}, false, :acknowledgement,
           "journaling-fallback",
           %{exploration_questions: 3, closing_invitation_sent: true, new_situation: false}}
        ] do
      test name do
        reply = unquote(Macro.escape(reply))
        state = unquote(Macro.escape(state))
        new_situation = unquote(new_situation)
        expected_response = unquote(expected_response)
        expected_model_version = unquote(expected_model_version)
        expected_exploration = unquote(Macro.escape(expected_exploration))

        result = TopicExploration.enforce(reply, state, new_situation, @inbound_id)

        assert_expected_response(result.response, expected_response)
        assert result.model_version == expected_model_version
        assert result.exploration == expected_exploration
      end
    end

    # Dispatched through a multi-clause function, not a `case` on the
    # comprehension-injected `expected_response` literal: per-clause
    # literal dispatch inside a generated test triggers a spurious
    # "clause will never match" compiler warning (same pattern noted
    # in #393 S1's `exploration_state_test.exs`).
    defp assert_expected_response(response, :closing_invitation) do
      assert response in JournalingFallback.closing_invitations()
    end

    defp assert_expected_response(response, :acknowledgement) do
      assert response in JournalingFallback.acknowledgements()
    end

    defp assert_expected_response(response, text) when is_binary(text) do
      assert response == text
    end

    test "leaves :guardrail untouched when a substitution happens" do
      reply = %{response: "¿Qué más pasó?", model_version: "phi-4-mini", guardrail: :diagnostic}
      state = %{questions: 3, closing_invitation_sent: false}

      result = TopicExploration.enforce(reply, state, false, @inbound_id)

      assert result.guardrail == :diagnostic
    end

    test "never substitutes when the limit reply already has no question" do
      reply = %{response: "Gracias por contarlo.", model_version: "phi-4-mini"}
      state = %{questions: 3, closing_invitation_sent: false}

      result = TopicExploration.enforce(reply, state, false, @inbound_id)

      assert result.response == "Gracias por contarlo."
      assert result.model_version == "phi-4-mini"

      assert result.exploration == %{
               exploration_questions: 3,
               closing_invitation_sent: true,
               new_situation: false
             }
    end
  end
end
