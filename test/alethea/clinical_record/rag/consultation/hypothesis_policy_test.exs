defmodule Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicyTest do
  @moduledoc """
  #229a: `Consultation.Hypothesis` value object contract, and
  `Consultation.HypothesisPolicy`'s two pure gates — the intent
  heuristic (D1) and the evidence/lexical `evaluate/2` gate (D3),
  including the mandatory server-owned disclaimer (D2).
  """
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.Rag.Consultation.{Hypothesis, HypothesisPolicy, Source}

  describe "Hypothesis struct contract" do
    test "raises ArgumentError when required keys are missing" do
      assert_raise ArgumentError, fn -> struct!(Hypothesis, %{}) end
    end

    test "disclaimer/0 pins the exact verbatim D2 literal (golden)" do
      assert Hypothesis.disclaimer() ==
               "Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica."
    end
  end

  describe "HypothesisPolicy.interpretive_intent?/1 — D1 intent heuristic" do
    @interpretive_phrases [
      {"¿Por qué empeoró el ánimo en marzo?", "causal: por que"},
      {"¿A qué se debe la irritabilidad?", "causal: a que se debe"},
      {"¿Podría deberse al cambio de trabajo?", "causal: podria deberse"},
      {"¿Puede deberse al estrés laboral?", "causal: puede deberse"},
      {"¿Se debe a la falta de sueño?", "causal: se debe a"},
      {"¿Qué explica el cambio de humor?", "causal: que explica"},
      {"¿Cómo se explica esta reacción?", "causal: como se explica"},
      {"¿Qué relación hay entre el insomnio y las discusiones?", "relational: que relacion"},
      {"¿Hay relación entre el trabajo y su ansiedad?", "relational: relacion entre"},
      {"¿Esto tiene que ver con la familia?", "relational: tiene que ver con"},
      {"¿Está relacionado con el cambio de casa?", "relational: esta relacionado"},
      {"¿Existe correlación entre el sueño y el ánimo?", "relational: correlacion"},
      {"¿Cómo influye el trabajo en su ansiedad?", "relational: influye"},
      {"¿Qué influencia tiene la familia en su ánimo?", "relational: influencia"},
      {"¿Hay un patrón en sus crisis?", "pattern: patron"},
      {"¿Existe una tendencia en sus recaídas?", "pattern: tendencia"},
      {"¿Por qué se repite este episodio?", "pattern: se repite"},
      {"¿Es un comportamiento recurrente?", "pattern: recurrente"},
      {"¿Qué significa este cambio de conducta?", "interpretive: que significa"},
      {"¿Cómo interpretas esta reacción?", "interpretive: como interpret"},
      {"¿Cuál sería la interpretación de este episodio?", "interpretive: interpretacion"},
      {"¿Tendría sentido que esté relacionado con el trabajo?",
       "interpretive: tendria sentido que"},
      {"¿Cuál es tu hipótesis sobre esta conducta?", "interpretive: hipotesis"}
    ]

    for {phrase, why} <- @interpretive_phrases do
      test "classifies as interpretive: #{why}" do
        assert HypothesisPolicy.interpretive_intent?(unquote(phrase))
      end
    end

    @factual_phrases [
      {"¿Cuándo reportó insomnio por última vez?", "cuando"},
      {"¿Cuántas veces mencionó a su pareja?", "cuantas veces"},
      {"¿Cuántos episodios tuvo este mes?", "cuantos"},
      {"¿Cuántas sesiones ha tenido?", "cuantas"},
      {"¿Qué dijo el paciente sobre su hermana?", "que dijo"},
      {"¿Qué día fue la última crisis?", "que dia"},
      {"¿En qué fecha comenzó el tratamiento?", "que fecha"},
      {"¿En qué sesión mencionó el conflicto laboral?", "en que sesion"},
      {"¿Quién asistió a la última sesión?", "quien"},
      {"Lista las sesiones de este mes", "lista"},
      {"Enumera los síntomas reportados", "enumera"},
      {"¿Cuándo fue la última vez que reportó insomnio?", "ultima vez"},
      {"¿Por qué faltó? ¿Qué día fue?", "veto wins over por que (AD2)"},
      {"Resume la última sesión", "no interpretive marker present"}
    ]

    for {phrase, why} <- @factual_phrases do
      test "does not classify as interpretive: #{why}" do
        refute HypothesisPolicy.interpretive_intent?(unquote(phrase))
      end
    end

    test "blank/whitespace-only input is never interpretive" do
      refute HypothesisPolicy.interpretive_intent?("")
      refute HypothesisPolicy.interpretive_intent?("   ")
    end

    test "is deterministic across repeated calls on the same ambiguous phrase" do
      phrase = "¿Qué relación hay entre el insomnio y las discusiones?"

      assert HypothesisPolicy.interpretive_intent?(phrase) ==
               HypothesisPolicy.interpretive_intent?(phrase)
    end

    test "is accent-fold invariant: 'por que' == 'por qué'" do
      assert HypothesisPolicy.interpretive_intent?("por que empeoro el animo") ==
               HypothesisPolicy.interpretive_intent?("por qué empeoró el ánimo")
    end
  end

  describe "HypothesisPolicy.evaluate/2 — D3 evidence + lexical gate" do
    defp fixture_result(overrides \\ %{}) do
      Map.merge(
        %{
          chunk_id: Ecto.UUID.generate(),
          source_resource_type: "clinical_note",
          source_resource_id: Ecto.UUID.generate(),
          source_occurred_at: ~U[2026-01-15 10:00:00.000000Z],
          target_behavior_id: nil,
          content: "El paciente reporta mejoría del ánimo esta semana."
        },
        overrides
      )
    end

    test "empty sources reject the hypothesis with :no_evidence" do
      assert HypothesisPolicy.evaluate("podría relacionarse con el trabajo", []) ==
               {:reject, :no_evidence}
    end

    test "empty statement rejects with :empty_statement (distinct from :no_evidence)" do
      assert HypothesisPolicy.evaluate("", [fixture_result()]) == {:reject, :empty_statement}
    end

    test "whitespace-only statement rejects with :empty_statement" do
      assert HypothesisPolicy.evaluate("   ", [fixture_result()]) == {:reject, :empty_statement}
    end

    # AD5 regression guard: the D2 disclaimer literally contains
    # "diagnóstico" and "recomendación terapéutica". The lexical scan
    # MUST run against candidate_text only, BEFORE the disclaimer is
    # attached to the resulting struct — never against the assembled
    # Hypothesis/disclaimer. A clean candidate statement must be
    # accepted even though the disclaimer attached afterward contains
    # those exact forbidden words.
    test "AD5 regression: a clean statement is accepted even though the disclaimer attached afterward contains forbidden words" do
      assert {:ok, %Hypothesis{} = hypothesis} =
               HypothesisPolicy.evaluate(
                 "podría relacionarse con el aumento de carga laboral",
                 [fixture_result()]
               )

      assert hypothesis.disclaimer == Hypothesis.disclaimer()
      assert hypothesis.disclaimer =~ "diagnóstico"
      assert hypothesis.disclaimer =~ "recomendación terapéutica"
    end

    test "sources equal Source.from_results/1 verbatim, order preserved, for N results" do
      results = [
        fixture_result(%{content: "primero"}),
        fixture_result(%{content: "segundo"}),
        fixture_result(%{content: "tercero"})
      ]

      assert {:ok, %Hypothesis{sources: sources}} =
               HypothesisPolicy.evaluate("podría tratarse de un patrón estacional", results)

      assert sources == Source.from_results(results)
    end

    # One base-form + one conjugated/inflected-form sample per pattern,
    # zipped 1:1 with HypothesisPolicy.diagnostic_patterns()' fixed order.
    @diagnostic_samples [
      {"tiene un diagnóstico previo de la última evaluación", "fue diagnosticado hace un año"},
      {"presenta un trastorno de ansiedad", "los trastornos alimentarios son comunes"},
      {"muestra un patrón patológico de evitación", "conducta patológica evidente"},
      {"padece de insomnio crónico", "podría padecer un cuadro de estrés"},
      {"sufre de ansiedad generalizada", "sufre de ansiedad generalizada"},
      {"cumple criterios para el diagnóstico", "cumple criterios para el diagnóstico"},
      {"presenta un cuadro clínico compatible", "presenta un cuadro clínico compatible"},
      {"compatible con dsm-v para ansiedad", "compatible con dsm 5 para ansiedad"},
      {"compatible con cie-10 para depresión", "compatible con cie-11 para depresión"}
    ]

    for {{base, conjugated}, index} <-
          Enum.with_index(
            Enum.zip(HypothesisPolicy.diagnostic_patterns(), @diagnostic_samples)
            |> Enum.map(fn {_pattern, samples} -> samples end)
          ) do
      test "diagnostic pattern ##{index} base form rejects with :diagnostic_language" do
        assert HypothesisPolicy.evaluate(unquote(base), [fixture_result()]) ==
                 {:reject, :diagnostic_language}
      end

      test "diagnostic pattern ##{index} conjugated form rejects with :diagnostic_language" do
        assert HypothesisPolicy.evaluate(unquote(conjugated), [fixture_result()]) ==
                 {:reject, :diagnostic_language}
      end
    end

    test "explicit diagnostic case: 'presenta un trastorno de ansiedad'" do
      assert HypothesisPolicy.evaluate("presenta un trastorno de ansiedad", [fixture_result()]) ==
               {:reject, :diagnostic_language}
    end

    # One base-form + one conjugated/inflected-form sample per pattern,
    # zipped 1:1 with HypothesisPolicy.prescriptive_patterns()' fixed order.
    @prescriptive_samples [
      {"se recomienda evaluación adicional", "recomiendo derivar a psiquiatría"},
      {"debe iniciar tratamiento pronto", "el tratamiento farmacológico ayudaría"},
      {"sería bueno iniciar terapia grupal", "sería bueno iniciar terapia grupal"},
      {"se debería prescribir un ansiolítico", "requiere una prescripción médica"},
      {"debería medicarse con ansiolíticos", "el medicamento indicado sería sertralina"},
      {"debería derivar al paciente al psiquiatra", "debería derivar al paciente al psiquiatra"},
      {"debería iniciar tratamiento cuanto antes", "debería derivar a un especialista"},
      {"hay que iniciar tratamiento cuanto antes", "hay que derivar al especialista"},
      {"se sugiere iniciar tratamiento farmacológico",
       "se sugiere tratamiento cognitivo conductual"}
    ]

    for {{base, conjugated}, index} <-
          Enum.with_index(
            Enum.zip(HypothesisPolicy.prescriptive_patterns(), @prescriptive_samples)
            |> Enum.map(fn {_pattern, samples} -> samples end)
          ) do
      test "prescriptive pattern ##{index} base form rejects with :prescriptive_language" do
        assert HypothesisPolicy.evaluate(unquote(base), [fixture_result()]) ==
                 {:reject, :prescriptive_language}
      end

      test "prescriptive pattern ##{index} conjugated form rejects with :prescriptive_language" do
        assert HypothesisPolicy.evaluate(unquote(conjugated), [fixture_result()]) ==
                 {:reject, :prescriptive_language}
      end
    end

    test "explicit prescriptive case: 'deberías iniciar tratamiento'" do
      assert HypothesisPolicy.evaluate("deberías iniciar tratamiento", [fixture_result()]) ==
               {:reject, :prescriptive_language}
    end

    test "explicit prescriptive case: 'recomiendo derivar a psiquiatría'" do
      assert HypothesisPolicy.evaluate("recomiendo derivar a psiquiatría", [fixture_result()]) ==
               {:reject, :prescriptive_language}
    end

    test "the recommend regex catches both 'recomendación'/'recomendamos' and the conjugation 'recomiendo'" do
      assert Regex.match?(~r/\brecom(iend|end)\w*\b/i, "recomiendo")
      assert Regex.match?(~r/\brecom(iend|end)\w*\b/i, "recomendación")
      assert Regex.match?(~r/\brecom(iend|end)\w*\b/i, "recomendamos")
    end

    test "negative control: legitimate tentative prose using 'sugiere'/'podría'/'es posible que' is accepted" do
      assert {:ok, %Hypothesis{}} =
               HypothesisPolicy.evaluate(
                 "el patrón sugiere que podría existir una relación; es posible que el estrés influya",
                 [fixture_result()]
               )
    end

    test "disclaimer is never derived from statement, even when the LLM echoes disclaimer-like wording" do
      llm_echo =
        "podría relacionarse con el estrés (nota: esta es una hipótesis para revisar, formulada de manera tentativa)"

      assert {:ok, %Hypothesis{} = hypothesis} =
               HypothesisPolicy.evaluate(llm_echo, [fixture_result()])

      assert hypothesis.disclaimer == Hypothesis.disclaimer()
      refute hypothesis.statement =~ Hypothesis.disclaimer()
    end
  end

  describe "Sole Constructor Gate — static scan" do
    test "no lib file outside hypothesis.ex/hypothesis_policy.ex constructs %Hypothesis{" do
      violations =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, ["hypothesis.ex", "hypothesis_policy.ex"]))
        |> Enum.filter(fn path ->
          path
          |> File.read!()
          |> Code.string_to_quoted!()
          |> constructs_hypothesis?()
        end)

      assert violations == []
    end
  end

  # Walks a file's AST distinguishing pattern position (function heads,
  # case/with/fn clauses, the left side of `=`/`<-`) from expression
  # position. Reading/destructuring `%Hypothesis{}` is legitimate anywhere
  # (e.g. HypothesisPanel pattern-matching on the value it was handed);
  # only *building* a new one outside hypothesis_policy.ex is the violation.
  defp constructs_hypothesis?(ast), do: hg_walk(ast, false)

  defp hg_walk({:%, _, [{:__aliases__, _, [:Hypothesis]}, {:%{}, _, _} = map]}, pattern?) do
    not pattern? or hg_walk(map, pattern?)
  end

  defp hg_walk({:def, _, [head, body]}, _pattern?),
    do: hg_walk(head, true) or hg_walk(body, false)

  defp hg_walk({:defp, _, [head, body]}, _pattern?),
    do: hg_walk(head, true) or hg_walk(body, false)

  defp hg_walk({:when, _, [head, guard]}, true), do: hg_walk(head, true) or hg_walk(guard, false)
  defp hg_walk({:->, _, [args, body]}, _pattern?), do: hg_walk(args, true) or hg_walk(body, false)
  defp hg_walk({:=, _, [lhs, rhs]}, _pattern?), do: hg_walk(lhs, true) or hg_walk(rhs, false)
  defp hg_walk({:<-, _, [lhs, rhs]}, _pattern?), do: hg_walk(lhs, true) or hg_walk(rhs, false)

  defp hg_walk({left, right}, pattern?), do: hg_walk(left, pattern?) or hg_walk(right, pattern?)
  defp hg_walk({_, _, args}, pattern?) when is_list(args), do: hg_walk(args, pattern?)
  defp hg_walk({_, _, _}, _pattern?), do: false
  defp hg_walk(list, pattern?) when is_list(list), do: Enum.any?(list, &hg_walk(&1, pattern?))
  defp hg_walk(_, _pattern?), do: false

  describe "HypothesisPolicy purity (static scan)" do
    test "hypothesis_policy.ex never touches Repo or clinical mutation functions" do
      source =
        Path.join([
          File.cwd!(),
          "lib",
          "alethea",
          "clinical_record",
          "rag",
          "consultation",
          "hypothesis_policy.ex"
        ])
        |> File.read!()

      refute source =~ "Repo."
      refute source =~ "create_clinical_note"
      refute source =~ "accept_ai_proposal"
    end
  end
end
