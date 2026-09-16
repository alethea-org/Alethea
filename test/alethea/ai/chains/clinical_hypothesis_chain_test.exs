defmodule Alethea.AI.Chains.ClinicalHypothesisChainTest do
  @moduledoc """
  RED-phase specs for `Alethea.AI.Chains.ClinicalHypothesisChain`
  (sdd/grounded-chat-229-hypothesis-policy, GitHub #229b). Exercises only
  the chain's pure functions (`build_prompt/1`, `parse/1`) plus
  `supported_providers/0` / `suggested_system_prompt/0` / `LLMConfig`
  resolution — no live LLM endpoint is invoked, matching
  `clinical_consultation_chain_test.exs`'s convention.

  Scenarios covered: Chain is local-only, Prompt carries no citation
  identifiers, Malformed output fails loud, Static scan proves no
  diagnosis/treatment call path (D3 layer 3).
  """
  use ExUnit.Case, async: true

  import Mox

  alias Alethea.AI.Chains.ClinicalHypothesisChain
  alias Alethea.AI.LLMConfig

  setup :verify_on_exit!

  @excerpts [
    "El paciente reporta insomnio recurrente los domingos por la noche.",
    "Refiere ansiedad anticipatoria antes de reuniones familiares."
  ]
  @question "¿Hay un patrón en las crisis de ansiedad del paciente?"

  describe "build_prompt/1" do
    test "numbers each excerpt" do
      prompt = ClinicalHypothesisChain.build_prompt(%{question: @question, excerpts: @excerpts})

      assert prompt =~ "1. El paciente reporta insomnio recurrente los domingos por la noche."
      assert prompt =~ "2. Refiere ansiedad anticipatoria antes de reuniones familiares."
    end

    test "embeds the question and the excerpt text only — no structural identifiers" do
      prompt = ClinicalHypothesisChain.build_prompt(%{question: @question, excerpts: @excerpts})

      assert prompt =~ @question
      assert prompt =~ "insomnio recurrente"

      refute prompt =~ "chunk_id"
      refute prompt =~ "resource_id"
      refute prompt =~ "target_behavior_id"
    end

    test "produces a prompt with exactly one numbered line per excerpt" do
      prompt =
        ClinicalHypothesisChain.build_prompt(%{
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
    test "extracts the hypothesis prose from a well-formed JSON response" do
      raw = ~s({"hypothesis": "Podría existir una relación entre el domingo y la anticipación."})

      assert ClinicalHypothesisChain.parse(raw) ==
               {:ok,
                %{hypothesis: "Podría existir una relación entre el domingo y la anticipación."}}
    end

    test "returns the model prose verbatim without adding anything" do
      raw = ~s({"hypothesis": "solo esto"})

      assert {:ok, %{hypothesis: "solo esto"}} = ClinicalHypothesisChain.parse(raw)
    end

    test "returns {:error, :unparseable} on malformed output" do
      for bad <- ["esto no es json", ~s({"otro": "valor"}), "", "   "] do
        assert ClinicalHypothesisChain.parse(bad) == {:error, :unparseable},
               "expected #{inspect(bad)} to be unparseable"
      end
    end

    test "returns {:error, :unparseable} on an empty hypothesis string (never degrades to blank)" do
      assert ClinicalHypothesisChain.parse(~s({"hypothesis": ""})) == {:error, :unparseable}
    end

    test "returns {:error, :unparseable} on a blank/whitespace hypothesis string" do
      assert ClinicalHypothesisChain.parse(~s({"hypothesis": "   \n  "})) ==
               {:error, :unparseable}
    end
  end

  describe "suggested_system_prompt/0 (interpretive-hypothesis golden)" do
    test "carries the verbatim never-a-diagnosis-nor-recommendation instruction" do
      prompt = ClinicalHypothesisChain.suggested_system_prompt()

      assert prompt =~ "NO es un diagnóstico ni una recomendación terapéutica"
    end

    test "carries the verbatim no-treatment-no-medication-no-referral rule" do
      prompt = ClinicalHypothesisChain.suggested_system_prompt()

      assert prompt =~ "no indiques tratamiento, medicación ni derivación"
    end

    test "carries the server-owns-disclaimer bullet" do
      prompt = ClinicalHypothesisChain.suggested_system_prompt()

      assert prompt =~ "el servidor lo añade"
    end

    test "instructs tentative phrasing, never a conclusion" do
      prompt = ClinicalHypothesisChain.suggested_system_prompt()

      assert prompt =~ "tentativo"
      refute prompt =~ "chunk_id"
    end
  end

  describe "supported_providers/0 (D2 — local-only)" do
    test "is exactly [:local]" do
      assert ClinicalHypothesisChain.supported_providers() == [:local]
    end

    test "rejects a :cloud provider" do
      refute :cloud in ClinicalHypothesisChain.supported_providers()
    end

    test "the chain module source never references the :cloud provider literal" do
      source =
        Path.join([
          File.cwd!(),
          "lib",
          "alethea",
          "ai",
          "chains",
          "clinical_hypothesis_chain.ex"
        ])
        |> File.read!()

      refute source =~ ":cloud"
    end
  end

  describe "suggested_max_tokens/0" do
    test "is 384" do
      assert ClinicalHypothesisChain.suggested_max_tokens() == 384
    end
  end

  describe "LLMConfig integration" do
    test "resolves a :consultation_hypothesis chain config pinned to the local provider" do
      assert {:ok, config, %Alethea.AI.ChatModels.OllamaChat{} = model} =
               LLMConfig.get_and_build(:consultation_hypothesis)

      assert model.model == config.model
      assert config.provider == :local
    end
  end

  describe "chain mock wiring (Mox against ChainBehaviour)" do
    test "the :test env points :clinical_hypothesis_chain at the Mox mock" do
      assert Application.get_env(:alethea, :clinical_hypothesis_chain) ==
               Alethea.AI.ClinicalHypothesisChainMock
    end

    test "the mock returns hypothesis prose derived only from the excerpts it is given" do
      expect(Alethea.AI.ClinicalHypothesisChainMock, :run, fn %{excerpts: excerpts} ->
        {:ok, %{hypothesis: "Hipótesis: " <> Enum.join(excerpts, " / ")}}
      end)

      assert {:ok, %{hypothesis: hypothesis}} =
               Alethea.AI.ClinicalHypothesisChainMock.run(%{
                 question: @question,
                 excerpts: ["dato clínico aislado"]
               })

      assert hypothesis =~ "dato clínico aislado"
    end
  end

  describe "structural safety" do
    test "the chain module source never references a diagnosis-writing or note-creating function" do
      source =
        Path.join([File.cwd!(), "lib", "alethea", "ai", "chains", "clinical_hypothesis_chain.ex"])
        |> File.read!()

      # Mutation entry points — verified to exist at lib/alethea/clinical_record.ex:
      refute source =~ "create_clinical_note"
      refute source =~ "accept_ai_proposal"
      refute source =~ "edit_ai_proposal"
      refute source =~ "discard_ai_proposal"
      refute source =~ "upsert_functional_analysis_draft"

      # Superset guard: the chain is pure text-in/text-out and must not
      # reach into the clinical write context or the repo at all.
      refute source =~ "Alethea.ClinicalRecord"
      refute source =~ "Repo."
    end
  end
end
