defmodule Alethea.AI.Chains.FunctionalAnalysisDraftChainTest do
  @moduledoc """
  Specs for `Alethea.AI.Chains.FunctionalAnalysisDraftChain` (#316 PR2):
  pure functions (`build_prompt/1`, `parse/1`), `supported_providers/0`,
  `suggested_system_prompt/0`, `LLMConfig` resolution, and AD3 field-name
  parity. No live LLM endpoint invoked (mirrors
  `clinical_hypothesis_chain_test.exs`).
  """
  use ExUnit.Case, async: true

  import Mox

  alias Alethea.AI.Chains.FunctionalAnalysisDraftChain
  alias Alethea.AI.LLMConfig
  alias Alethea.ClinicalRecord.FunctionalAnalysisContent

  setup :verify_on_exit!

  @evidence [
    "El paciente reporta insomnio recurrente los domingos por la noche.",
    "Refiere ansiedad anticipatoria antes de reuniones familiares."
  ]

  @clean_fields %{
    "antecedents_distal" => "Discusión familiar el sábado.",
    "antecedents_immediate" => "Mensaje de texto recibido antes de dormir.",
    "organism_sleep" => "Durmió 4 horas.",
    "organism_pain_or_discomfort" => "Sin dolor referido.",
    "organism_hunger_or_nutrition" => "No desayunó.",
    "organism_learning_history" => "Historial de evitación ante conflicto.",
    "response_physiological" => "Taquicardia.",
    "response_cognitive" => "Pensó que la situación era insostenible.",
    "response_motor" => "Se encerró en su habitación.",
    "consequences_short_term" => "Alivio inmediato de la tensión.",
    "consequences_long_term" => "Mayor aislamiento social."
  }

  @clean_json Jason.encode!(@clean_fields)

  describe "build_prompt/1" do
    test "numbers each evidence line" do
      prompt = FunctionalAnalysisDraftChain.build_prompt(@evidence)

      assert prompt =~ "1. El paciente reporta insomnio recurrente los domingos por la noche."
      assert prompt =~ "2. Refiere ansiedad anticipatoria antes de reuniones familiares."
    end

    test "embeds the evidence text only — no structural identifiers" do
      prompt = FunctionalAnalysisDraftChain.build_prompt(@evidence)

      assert prompt =~ "insomnio recurrente"

      refute prompt =~ "chunk_id"
      refute prompt =~ "resource_id"
      refute prompt =~ "target_behavior_id"
    end

    test "produces a prompt with exactly one numbered line per evidence entry" do
      prompt = FunctionalAnalysisDraftChain.build_prompt(["uno", "dos", "tres"])

      assert prompt =~ "1. uno"
      assert prompt =~ "2. dos"
      assert prompt =~ "3. tres"
      refute prompt =~ "4. "
    end
  end

  describe "suggested_system_prompt/0 (E-O-R-C golden)" do
    test "carries the four verbatim NUNCA rules" do
      prompt = FunctionalAnalysisDraftChain.suggested_system_prompt()

      assert prompt =~ "NUNCA diagnostiques"
      assert prompt =~ "NUNCA recomiendes tratamiento, medicación, derivación ni intervención."
      assert prompt =~ "NUNCA uses tono de hecho consumado."

      assert prompt =~
               "NUNCA completes con conocimiento general: usa solo la evidencia entregada."
    end

    test "names all eleven E-O-R-C fields" do
      prompt = FunctionalAnalysisDraftChain.suggested_system_prompt()

      for field <- FunctionalAnalysisDraftChain.eorc_fields() do
        assert prompt =~ field, "expected prompt to name field #{field}"
      end
    end

    test "never mentions previous_notes" do
      prompt = FunctionalAnalysisDraftChain.suggested_system_prompt()

      refute prompt =~ "previous_notes"
    end
  end

  describe "parse/1 — clean and fenced equivalence" do
    test "clean JSON parses all eleven fields" do
      assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(@clean_json)
      assert map_size(fields) == 11
      assert fields["antecedents_distal"] == "Discusión familiar el sábado."
      assert fields["consequences_long_term"] == "Mayor aislamiento social."
    end

    test "fenced variants (leading-only, trailing-only, both) parse identically to clean JSON" do
      for fenced <- [
            "```json\n" <> @clean_json <> "\n```",
            "```json\n" <> @clean_json,
            @clean_json <> "\n```"
          ] do
        assert FunctionalAnalysisDraftChain.parse(fenced) ==
                 FunctionalAnalysisDraftChain.parse(@clean_json)
      end
    end

    test "schema-echoed response (properties wrapper) extracts fields" do
      wrapped = Jason.encode!(%{"properties" => @clean_fields})

      assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(wrapped)
      assert map_size(fields) == 11
      assert fields["antecedents_distal"] == "Discusión familiar el sábado."
    end

    test "schema-shape echo (non-binary values) is unparseable" do
      shape_echo =
        Jason.encode!(%{
          "antecedents_distal" => %{"type" => "string"},
          "antecedents_immediate" => %{"type" => "string"}
        })

      assert FunctionalAnalysisDraftChain.parse(shape_echo) == {:error, :unparseable}
    end

    test "zero recognizable fields is unparseable" do
      assert FunctionalAnalysisDraftChain.parse(~s({"otro": "valor"})) == {:error, :unparseable}
    end

    test "non-JSON input is unparseable" do
      assert FunctionalAnalysisDraftChain.parse("esto no es json") == {:error, :unparseable}
    end
  end

  describe "parse/1 — partial tolerance (D4)" do
    test "8-of-11 valid fields returns exactly those 8 keys" do
      partial =
        Jason.encode!(%{
          "antecedents_distal" => "Discusión familiar.",
          "antecedents_immediate" => "Mensaje recibido.",
          "organism_sleep" => "Durmió poco.",
          "organism_pain_or_discomfort" => "Sin dolor.",
          "organism_hunger_or_nutrition" => "No comió.",
          "response_physiological" => "Taquicardia.",
          "response_cognitive" => "Pensamiento catastrófico.",
          "response_motor" => "Se aisló."
        })

      assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(partial)
      assert map_size(fields) == 8

      for absent <- [
            "organism_learning_history",
            "consequences_short_term",
            "consequences_long_term"
          ] do
        refute Map.has_key?(fields, absent)
      end
    end

    test "model-emitted empty string means the key is absent, not blanked" do
      partial =
        Jason.encode!(%{
          "antecedents_distal" => "Discusión familiar.",
          "antecedents_immediate" => ""
        })

      assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(partial)
      assert map_size(fields) == 1
      refute Map.has_key?(fields, "antecedents_immediate")
    end
  end

  describe "parse/1 — per-field diagnostic/prescriptive blanking (D3)" do
    test "diagnostic or prescriptive pattern match blanks only that field, siblings untouched" do
      cases = [
        {"response_cognitive", "El paciente cumple criterios de un trastorno de ansiedad.",
         "response_motor", "Se encerró en su habitación."},
        {"consequences_long_term", "Se recomienda iniciar tratamiento farmacológico.",
         "consequences_short_term", "Alivio inmediato."}
      ]

      for {flagged_field, flagged_text, sibling_field, sibling_text} <- cases do
        json = Jason.encode!(%{flagged_field => flagged_text, sibling_field => sibling_text})

        assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(json)
        assert fields[flagged_field] == ""
        assert fields[sibling_field] == sibling_text
      end
    end

    test "absent key vs. blanked key are distinguishable" do
      json =
        Jason.encode!(%{
          "response_cognitive" => "El paciente padece un trastorno de ansiedad."
        })

      assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(json)
      assert fields["response_cognitive"] == ""
      refute Map.has_key?(fields, "antecedents_distal")
    end

    test "all eleven fields blanked still returns {:ok, 11 keys}" do
      flagged_value = "Diagnóstico de un trastorno."

      flagged_json =
        FunctionalAnalysisDraftChain.eorc_fields()
        |> Map.new(&{&1, flagged_value})
        |> Jason.encode!()

      assert {:ok, fields} = FunctionalAnalysisDraftChain.parse(flagged_json)
      assert map_size(fields) == 11
      assert Enum.all?(Map.values(fields), &(&1 == ""))
    end
  end

  describe "supported_providers/0 (local-only, decrypted PHI in prompt)" do
    test "is exactly [:local], rejects :cloud" do
      assert FunctionalAnalysisDraftChain.supported_providers() == [:local]
      refute :cloud in FunctionalAnalysisDraftChain.supported_providers()
    end
  end

  describe "suggested_max_tokens/0" do
    test "is 1024" do
      assert FunctionalAnalysisDraftChain.suggested_max_tokens() == 1024
    end
  end

  describe "LLMConfig integration" do
    test "resolves a :functional_analysis_draft chain config pinned to the local provider" do
      assert {:ok, config, %Alethea.AI.ChatModels.OllamaChat{} = model} =
               LLMConfig.get_and_build(:functional_analysis_draft)

      assert model.model == config.model
      assert config.provider == :local
    end
  end

  describe "chain mock wiring (Mox against ChainBehaviour)" do
    test "the :test env points :functional_analysis_draft_chain at the Mox mock" do
      assert Application.get_env(:alethea, :functional_analysis_draft_chain) ==
               Alethea.AI.FunctionalAnalysisDraftChainMock
    end

    test "the mock returns a draft map derived only from the evidence it is given" do
      expect(Alethea.AI.FunctionalAnalysisDraftChainMock, :run, fn %{sanitized_evidence: texts} ->
        {:ok, %{"antecedents_distal" => Enum.join(texts, " / ")}}
      end)

      assert {:ok, %{"antecedents_distal" => value}} =
               Alethea.AI.FunctionalAnalysisDraftChainMock.run(%{
                 sanitized_evidence: ["dato clínico aislado"]
               })

      assert value =~ "dato clínico aislado"
    end
  end

  describe "AD3 — eorc_fields/0 parity with FunctionalAnalysisContent" do
    test "eorc_fields/0 equals the struct's keys minus previous_notes" do
      expected =
        %FunctionalAnalysisContent{}
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.reject(&(&1 == :previous_notes))
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      assert Enum.sort(FunctionalAnalysisDraftChain.eorc_fields()) == expected
    end
  end

  describe "structural safety" do
    test "source never references a mutation function, :cloud, or the clinical-record context" do
      source = chain_source()

      # Mutation entry points — verified to exist at lib/alethea/clinical_record.ex:
      refute source =~ "create_clinical_note"
      refute source =~ "accept_ai_proposal"
      refute source =~ "edit_ai_proposal"
      refute source =~ "discard_ai_proposal"
      refute source =~ "upsert_functional_analysis_draft"
      refute source =~ "upsert_functional_analysis_content"
      refute source =~ ":cloud"

      # Superset guard: the chain is pure text-in/text-out and must not
      # reach into the clinical write context or the repo at all.
      refute source =~ "Alethea.ClinicalRecord"
      refute source =~ "Repo."
    end
  end

  defp chain_source do
    File.read!(Path.join(File.cwd!(), "lib/alethea/ai/chains/functional_analysis_draft_chain.ex"))
  end
end
