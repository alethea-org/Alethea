defmodule Alethea.ClinicalRecord.FunctionalAnalysisContentTest do
  use ExUnit.Case, async: true

  alias Alethea.ClinicalRecord.FunctionalAnalysisContent

  @params %{
    "antecedents_distal" => "Distal antecedent",
    "antecedents_immediate" => "Immediate antecedent",
    "organism_sleep" => "Poor sleep",
    "organism_pain_or_discomfort" => "Back pain",
    "organism_hunger_or_nutrition" => "Skipped lunch",
    "organism_learning_history" => "Avoidance was reinforced",
    "response_physiological" => "Tachycardia",
    "response_cognitive" => "I cannot cope",
    "response_motor" => "Leaves the room",
    "consequences_short_term" => "Relief",
    "consequences_long_term" => "More avoidance",
    "previous_notes" => "Preserved clinician notes"
  }

  describe "new/1" do
    test "constructs all E-O-R-C fields and preserved previous notes from string-keyed params" do
      assert %FunctionalAnalysisContent{
               antecedents_distal: "Distal antecedent",
               antecedents_immediate: "Immediate antecedent",
               organism_sleep: "Poor sleep",
               organism_pain_or_discomfort: "Back pain",
               organism_hunger_or_nutrition: "Skipped lunch",
               organism_learning_history: "Avoidance was reinforced",
               response_physiological: "Tachycardia",
               response_cognitive: "I cannot cope",
               response_motor: "Leaves the room",
               consequences_short_term: "Relief",
               consequences_long_term: "More avoidance",
               previous_notes: "Preserved clinician notes"
             } = FunctionalAnalysisContent.new(@params)
    end

    test "normalizes missing, nil, and non-string values to explicit empty strings" do
      content =
        FunctionalAnalysisContent.new(%{
          "antecedents_distal" => nil,
          "response_motor" => 42,
          "unknown" => "ignored"
        })

      assert content == %FunctionalAnalysisContent{}
    end

    test "does not infer E-O-R-C fields from previous notes" do
      content =
        FunctionalAnalysisContent.new(%{
          "previous_notes" => "Antecedente: dormí mal. Respuesta: evité salir."
        })

      assert content.previous_notes == "Antecedente: dormí mal. Respuesta: evité salir."
      assert content.antecedents_distal == ""
      assert content.antecedents_immediate == ""
      assert content.organism_sleep == ""
      assert content.response_cognitive == ""
      assert content.consequences_long_term == ""
    end
  end

  describe "serialize/1 and parse/1" do
    test "round-trips every field, including empty fields and pending previous notes" do
      content = FunctionalAnalysisContent.new(@params)

      assert {:structured, ^content} =
               content
               |> FunctionalAnalysisContent.serialize()
               |> FunctionalAnalysisContent.parse()
    end

    test "keeps every empty field explicit and round-trippable" do
      content = FunctionalAnalysisContent.new(%{})
      body = FunctionalAnalysisContent.serialize(content)

      assert {:structured, ^content} = FunctionalAnalysisContent.parse(body)
      assert length(Regex.scan(~r/\["[^"]+",""\]/, body)) == 12
    end

    test "serializes deterministically with a versioned sentinel and fixed field order" do
      content = FunctionalAnalysisContent.new(@params)

      expected =
        "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n" <>
          ~S(["alethea.functional-analysis-content",1,[["antecedents_distal","Distal antecedent"],["antecedents_immediate","Immediate antecedent"],["organism_sleep","Poor sleep"],["organism_pain_or_discomfort","Back pain"],["organism_hunger_or_nutrition","Skipped lunch"],["organism_learning_history","Avoidance was reinforced"],["response_physiological","Tachycardia"],["response_cognitive","I cannot cope"],["response_motor","Leaves the room"],["consequences_short_term","Relief"],["consequences_long_term","More avoidance"],["previous_notes","Preserved clinician notes"]]])

      assert FunctionalAnalysisContent.serialize(content) == expected

      assert FunctionalAnalysisContent.serialize(content) ==
               FunctionalAnalysisContent.serialize(content)
    end

    test "preserves arbitrary legacy text byte-for-byte as previous notes" do
      legacy = "Antecedentes:\r\n  texto libre  \nConducta: nada clasificado\n"

      assert {:legacy, content} = FunctionalAnalysisContent.parse(legacy)
      assert content == %FunctionalAnalysisContent{previous_notes: legacy}
    end

    test "does not misclassify sentinel-like legacy text" do
      legacy = "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT is only a heading\nfree text"

      assert {:legacy, %FunctionalAnalysisContent{previous_notes: ^legacy}} =
               FunctionalAnalysisContent.parse(legacy)
    end

    test "fails closed for malformed structured envelopes" do
      malformed = "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n{not-json"

      assert {:legacy, %FunctionalAnalysisContent{previous_notes: ^malformed}} =
               FunctionalAnalysisContent.parse(malformed)
    end

    test "fails closed for unsupported structured-envelope versions" do
      unsupported =
        "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n" <>
          ~S(["alethea.functional-analysis-content",2,[]])

      assert {:legacy, %FunctionalAnalysisContent{previous_notes: ^unsupported}} =
               FunctionalAnalysisContent.parse(unsupported)
    end

    test "fails closed when a structured envelope omits, reorders, or mistypes fields" do
      malformed_bodies = [
        "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n" <>
          ~S(["alethea.functional-analysis-content",1,[]]),
        "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n" <>
          ~S(["alethea.functional-analysis-content",1,[["previous_notes","first"]]]),
        "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n" <>
          ~S(["alethea.functional-analysis-content",1,[["antecedents_distal",42]]])
      ]

      for body <- malformed_bodies do
        assert {:legacy, %FunctionalAnalysisContent{previous_notes: ^body}} =
                 FunctionalAnalysisContent.parse(body)
      end
    end
  end
end
