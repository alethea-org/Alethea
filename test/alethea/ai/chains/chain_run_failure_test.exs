defmodule Alethea.AI.Chains.ChainRunFailureTest do
  @moduledoc """
  Every chain that runs a model reports a failed run the same way (issue
  #402): a small tagged reason, with the prompt content absent from the
  returned term, from the telemetry metadata and from the logs.

  The real chains run against `Req.Test` standing in for Ollama, so the
  failure is the three-element error LangChain's `LLMChain.run/1` really
  returns. `SessionSummaryChain` has its own file; this one covers the
  other six.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Alethea.AI.Chains.{
    ClinicalConsultationChain,
    ClinicalHypothesisChain,
    FunctionalAnalysisDraftChain,
    GuidedConversationChain,
    PatternProposalChain,
    WeeklySummaryChain
  }

  # A recognisable synthetic stand-in for clinical text in a prompt.
  @marker "marcador-sintetico-zzqx-cadena"

  @chains [
    {ClinicalConsultationChain, :clinical_consultation,
     %{question: "¿#{@marker}?", excerpts: [@marker]}},
    {ClinicalHypothesisChain, :clinical_hypothesis,
     %{question: "¿#{@marker}?", excerpts: [@marker]}},
    {FunctionalAnalysisDraftChain, :functional_analysis_draft, %{sanitized_evidence: [@marker]}},
    {GuidedConversationChain, :guided_conversation,
     %{
       sanitized_content: @marker,
       history: [%{role: :patient, content: @marker}],
       message_id: "msg-failure"
     }},
    {PatternProposalChain, :pattern_proposal, %{sanitized_evidence: [@marker]}},
    {WeeklySummaryChain, :weekly_summary, %{summaries: [@marker], trends: []}}
  ]

  setup do
    Application.put_env(:alethea, :ollama_chat_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:alethea, :ollama_chat_req_options) end)

    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:alethea, :ai, :chain, :stop],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:chain_stop, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp printed(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  for {chain, name, params} <- @chains do
    test "#{inspect(chain)} reports a failed run as a tagged reason without prompt content" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      {result, log} = with_log(fn -> unquote(chain).run(unquote(Macro.escape(params))) end)

      assert result == {:error, {:llm_run_failed, :untyped}}

      assert_received {:chain_stop, %{chain: unquote(name)} = metadata}
      refute printed(metadata) =~ @marker
      refute printed(result) =~ @marker
      refute log =~ @marker
    end
  end

  test "the guided conversation telemetry reports the tagged reason" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    capture_log(fn ->
      GuidedConversationChain.run(%{sanitized_content: @marker, history: [], message_id: "m"})
    end)

    assert_received {:chain_stop, %{chain: :guided_conversation, success: false} = metadata}
    assert metadata.error == "{:llm_run_failed, :untyped}"
  end
end
