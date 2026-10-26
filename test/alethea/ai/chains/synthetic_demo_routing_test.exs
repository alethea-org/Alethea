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
    SessionSummaryChain,
    WeeklySummaryChain
  }

  @chains [
    ClinicalConsultationChain,
    ClinicalHypothesisChain,
    FunctionalAnalysisDraftChain,
    PatternProposalChain,
    SessionSummaryChain,
    WeeklySummaryChain
  ]

  setup do
    originals = Map.new(@chains, &{&1, Application.fetch_env(:alethea, &1)})
    original_req = Application.fetch_env(:alethea, :anthropic_chat_req_options)

    for chain <- @chains do
      Application.put_env(:alethea, chain,
        provider: :anthropic,
        model: "claude-test-model",
        api_key: "synthetic-key",
        endpoint_url: "https://api.anthropic.com/v1/messages"
      )
    end

    Application.put_env(:alethea, :anthropic_chat_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {key, original} <- Map.put(originals, :anthropic_chat_req_options, original_req) do
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

    assert {:ok, _result} = PatternProposalChain.run(%{sanitized_evidence: ["Evidencia"]})
  end

  test "session summary returns Claude's reply" do
    expect_reply("1. Estable")

    assert {:ok, %{summary: "1. Estable"}} = SessionSummaryChain.run(["Texto sintetico"], [])
  end

  test "weekly summary and functional analysis reach Claude without tools" do
    for run <- [
          fn -> WeeklySummaryChain.run(["Resumen sintetico"], []) end,
          fn -> FunctionalAnalysisDraftChain.run(%{sanitized_evidence: ["Evidencia"]}) end
        ] do
      expect_reply("{}")
      run.()
      Req.Test.verify!(__MODULE__)
    end
  end

  # Asserts the chain sent a tool-free text request, then answers it.
  defp expect_reply(text) do
    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["model"] == "claude-test-model"
      refute Map.has_key?(payload, "tools")

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => "end_turn"
      })
    end)
  end
end
