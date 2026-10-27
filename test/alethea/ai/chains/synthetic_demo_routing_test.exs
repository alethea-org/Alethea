defmodule Alethea.AI.Chains.SyntheticDemoRoutingTest do
  @moduledoc """
  The synthetic demo profile (DEMO_SYNTHETIC_DATA=true) routes the six
  non-guided chains to Anthropic. These tests run each routed chain through
  `AnthropicChat` (stubbed with `Req.Test`) to prove the text-only adapter
  serves them: none of them sends tools, and each parses Claude's reply.
  """

  use ExUnit.Case, async: false

  alias Alethea.AI.Chains.{
    ClinicalConsultationChain,
    ClinicalHypothesisChain,
    FunctionalAnalysisDraftChain,
    PatternProposalChain,
    RunningSummaryChain,
    SessionSummaryChain,
    WeeklySummaryChain
  }

  @chains [
    ClinicalConsultationChain,
    ClinicalHypothesisChain,
    FunctionalAnalysisDraftChain,
    PatternProposalChain,
    RunningSummaryChain,
    SessionSummaryChain,
    WeeklySummaryChain
  ]

  setup do
    keys = [Alethea.AI.LLMConfig, :anthropic_chat_req_options | @chains]
    originals = Map.new(keys, &{&1, Application.fetch_env(:alethea, &1)})

    # Same wiring as config/runtime.exs: each chain gets only provider and
    # model; the key and endpoint come from the global Anthropic entry.
    for chain <- @chains do
      Application.put_env(:alethea, chain, provider: :anthropic, model: "claude-test-model")
    end

    global = Application.get_env(:alethea, Alethea.AI.LLMConfig, [])

    Application.put_env(
      :alethea,
      Alethea.AI.LLMConfig,
      Keyword.put(global, :anthropic,
        endpoint_url: "https://api.anthropic.com/v1/messages",
        api_key: "synthetic-global-key"
      )
    )

    Application.put_env(:alethea, :anthropic_chat_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {key, original} <- originals do
        case original do
          {:ok, value} -> Application.put_env(:alethea, key, value)
          :error -> Application.delete_env(:alethea, key)
        end
      end
    end)

    :ok
  end

  test "clinical consultation parses Claude's reply" do
    expect_reply(~s({"synthesis": "Sintesis sintetica."}))

    assert {:ok, %{synthesis: "Sintesis sintetica."}} =
             ClinicalConsultationChain.run(%{question: "¿Cómo evoluciona?", excerpts: ["Uno"]})
  end

  test "clinical hypothesis parses Claude's reply" do
    expect_reply(~s({"hypothesis": "Hipotesis sintetica."}))

    assert {:ok, %{hypothesis: "Hipotesis sintetica."}} =
             ClinicalHypothesisChain.run(%{question: "¿Qué relación hay?", excerpts: ["Uno"]})
  end

  test "pattern proposal parses Claude's reply" do
    expect_reply(~s({"proposals": ["Patron sintetico"]}))

    assert {:ok, %{proposals: ["Patron sintetico"]}} =
             PatternProposalChain.run(%{sanitized_evidence: ["Evidencia"]})
  end

  test "running summary returns Claude's reply" do
    expect_reply("Resumen factual sintetico.")

    assert {:ok, %{summary: "Resumen factual sintetico.", truncated: false}} =
             RunningSummaryChain.run(%{turns: [%{role: :patient, content: "Hola"}]})
  end

  test "session summary returns Claude's reply" do
    expect_reply("1. Estable")

    assert {:ok, %{summary: "1. Estable"}} = SessionSummaryChain.run(["Texto sintetico"], [])
  end

  test "weekly summary parses Claude's reply" do
    expect_reply(
      Jason.encode!(%{
        "summary_text" => "Semana estable.",
        "status_level" => "Estable",
        "anxiety_score" => 0.2,
        "social_score" => 0.5,
        "emotional_range" => %{
          "joy" => 0.4,
          "sadness" => 0.1,
          "anger" => 0.0,
          "fear" => 0.1,
          "neutral" => 0.4
        },
        "crisis_events" => 0,
        "session_count" => 1
      })
    )

    assert {:ok, %{summary_text: "Semana estable.", status_level: "Estable"}} =
             WeeklySummaryChain.run(["Resumen sintetico"], [])
  end

  test "functional analysis draft parses Claude's reply" do
    fields = %{
      "antecedents_distal" => "Distal.",
      "antecedents_immediate" => "Inmediato.",
      "organism_sleep" => "Sueno.",
      "organism_pain_or_discomfort" => "Sin dolor.",
      "organism_hunger_or_nutrition" => "Comio.",
      "organism_learning_history" => "Historia.",
      "response_physiological" => "Fisiologica.",
      "response_cognitive" => "Cognitiva.",
      "response_motor" => "Motora.",
      "consequences_short_term" => "Corto plazo.",
      "consequences_long_term" => "Largo plazo."
    }

    expect_reply(Jason.encode!(fields))

    assert {:ok, draft} = FunctionalAnalysisDraftChain.run(%{sanitized_evidence: ["Evidencia"]})
    assert inspect(draft) =~ "Largo plazo."
  end

  # Asserts the chain sent a tool-free text request, then answers it.
  defp expect_reply(text) do
    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["model"] == "claude-test-model"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["synthetic-global-key"]
      refute Map.has_key?(payload, "tools")

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => "end_turn"
      })
    end)
  end
end
