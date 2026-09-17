defmodule Alethea.AI.Chains.ClinicalConsultationChainTest do
  @moduledoc """
  RED-phase specs for `Alethea.AI.Chains.ClinicalConsultationChain`
  (sdd/grounded-clinical-chat-initial, GitHub #223, PR #226b). Exercises
  only the chain's pure functions (`build_prompt/1`, `parse/1`) plus
  `supported_providers/0` / `suggested_system_prompt/0` / `LLMConfig`
  resolution — no live LLM endpoint is invoked, matching the existing
  convention for `PatternProposalChain` (its `run/1` orchestration is
  exercised indirectly through its worker via Mox).

  Scenarios covered: Local-Only Synthesis No External Leak, Cloud
  provider is rejected for this chain, Provider-failure outcome is a safe
  state (AD8), Server-Derived Source Provenance (grounding).
  """
  use ExUnit.Case, async: true

  import Mox

  alias Alethea.AI.Chains.ClinicalConsultationChain
  alias Alethea.AI.LLMConfig

  setup :verify_on_exit!

  @excerpts [
    "El paciente reporta que durmió mal tres noches seguidas.",
    "Refiere mayor irritabilidad con su pareja durante la semana."
  ]
  @question "¿Cómo ha estado el sueño del paciente?"

  describe "build_prompt/1" do
    test "numbers each excerpt" do
      prompt = ClinicalConsultationChain.build_prompt(%{question: @question, excerpts: @excerpts})

      assert prompt =~ "1. El paciente reporta que durmió mal tres noches seguidas."
      assert prompt =~ "2. Refiere mayor irritabilidad con su pareja durante la semana."
    end

    test "embeds the question and the excerpt text only — no structural identifiers" do
      prompt = ClinicalConsultationChain.build_prompt(%{question: @question, excerpts: @excerpts})

      assert prompt =~ @question
      assert prompt =~ "durmió mal tres noches seguidas"

      refute prompt =~ "chunk_id"
      refute prompt =~ "resource_id"
      refute prompt =~ "target_behavior_id"
      # nothing from the system prompt / general knowledge leaks into the user turn
      refute prompt =~ "conocimiento general"
    end

    test "produces a prompt with exactly one numbered line per excerpt" do
      prompt =
        ClinicalConsultationChain.build_prompt(%{
          question: "¿?",
          excerpts: ["uno", "dos", "tres"]
        })

      assert prompt =~ "1. uno"
      assert prompt =~ "2. dos"
      assert prompt =~ "3. tres"
      refute prompt =~ "4. "
    end
  end

  describe "parse/1" do
    test "extracts the synthesis prose from a well-formed JSON response" do
      raw = ~s({"synthesis": "El paciente muestra una mejoría sostenida del ánimo."})

      assert ClinicalConsultationChain.parse(raw) ==
               {:ok, %{synthesis: "El paciente muestra una mejoría sostenida del ánimo."}}
    end

    test "returns the model prose verbatim without adding anything" do
      raw = ~s({"synthesis": "solo esto"})

      assert {:ok, %{synthesis: "solo esto"}} = ClinicalConsultationChain.parse(raw)
    end

    test "returns {:error, :unparseable} on malformed JSON" do
      assert ClinicalConsultationChain.parse("esto no es json") == {:error, :unparseable}
    end

    test "returns {:error, :unparseable} on an empty synthesis string (never degrades to \"\")" do
      assert ClinicalConsultationChain.parse(~s({"synthesis": ""})) == {:error, :unparseable}
    end

    test "returns {:error, :unparseable} on a blank/whitespace synthesis string" do
      assert ClinicalConsultationChain.parse(~s({"synthesis": "   \n  "})) ==
               {:error, :unparseable}
    end

    test "returns {:error, :unparseable} when the synthesis key is missing" do
      assert ClinicalConsultationChain.parse(~s({"otro": "valor"})) == {:error, :unparseable}
    end
  end

  describe "supported_providers/0 (D2 — local-only)" do
    test "is exactly [:local]" do
      assert ClinicalConsultationChain.supported_providers() == [:local]
    end

    test "rejects a :cloud provider" do
      refute :cloud in ClinicalConsultationChain.supported_providers()
    end

    test "the chain module source never references the :cloud provider literal" do
      source =
        Path.join([
          File.cwd!(),
          "lib",
          "alethea",
          "ai",
          "chains",
          "clinical_consultation_chain.ex"
        ])
        |> File.read!()

      refute source =~ ":cloud"
    end
  end

  describe "suggested_system_prompt/0 (grounding + no-fallback golden)" do
    test "carries the verbatim no-fallback grounding instruction" do
      prompt = ClinicalConsultationChain.suggested_system_prompt()

      assert prompt =~
               "no diagnostiques, no recomiendes tratamiento, no completes con conocimiento general; si los fragmentos no alcanzan, dilo"
    end

    test "instructs the model to synthesize only from the provided fragments" do
      prompt = ClinicalConsultationChain.suggested_system_prompt()

      assert prompt =~ "fragmentos"
      refute prompt =~ "chunk_id"
    end
  end

  describe "suggested_max_tokens/0" do
    test "is 512" do
      assert ClinicalConsultationChain.suggested_max_tokens() == 512
    end
  end

  describe "LLMConfig integration" do
    test "resolves a :consultation_synthesis chain config pinned to the local provider" do
      assert {:ok, config, %Alethea.AI.ChatModels.OllamaChat{} = model} =
               LLMConfig.get_and_build(:consultation_synthesis)

      assert model.model == config.model
      assert config.provider == :local
    end
  end

  describe "chain mock wiring (Mox against ChainBehaviour)" do
    test "the :test env points :clinical_consultation_chain at the Mox mock" do
      assert Application.get_env(:alethea, :clinical_consultation_chain) ==
               Alethea.AI.ClinicalConsultationChainMock
    end

    test "the mock returns synthesis prose derived only from the excerpts it is given" do
      expect(Alethea.AI.ClinicalConsultationChainMock, :run, fn %{excerpts: excerpts} ->
        {:ok, %{synthesis: "Síntesis: " <> Enum.join(excerpts, " / ")}}
      end)

      assert {:ok, %{synthesis: synthesis}} =
               Alethea.AI.ClinicalConsultationChainMock.run(%{
                 question: @question,
                 excerpts: ["dato clínico aislado"]
               })

      assert synthesis =~ "dato clínico aislado"
    end
  end
end
