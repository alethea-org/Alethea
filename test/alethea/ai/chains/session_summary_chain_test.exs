defmodule Alethea.AI.Chains.SessionSummaryChainTest do
  @moduledoc """
  Drives the real `SessionSummaryChain` against a controlled model
  (issue #402). `Req.Test` stands in for Ollama, so the chain, the app's
  chat-model adapter and LangChain's `LLMChain.run/1` all run for real and
  nothing leaves the process.

  A failed run must come back as a small tagged reason. The session text
  is clinical content: it may not travel in the returned term, in the
  telemetry metadata or in the logs.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Alethea.AI.Chains.SessionSummaryChain

  # A recognisable synthetic stand-in for a patient's message.
  @marker "marcador-sintetico-zzqx-resumen"

  setup do
    Application.put_env(:alethea, :ollama_chat_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:alethea, :ollama_chat_req_options) end)
    :ok
  end

  defp attach_stop_handler do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:alethea, :ai, :chain, :stop],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:chain_stop, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "returns the summary when the model answers" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"message" => %{"content" => "1. Estable"}, "done_reason" => "stop"})
    end)

    assert {:ok, %{summary: "1. Estable", tokens_used: tokens}} =
             SessionSummaryChain.run([@marker], [])

    assert is_integer(tokens)
  end

  test "a provider failure is a tagged reason that carries no session text" do
    attach_stop_handler()

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    {result, log} =
      with_log(fn -> SessionSummaryChain.run([@marker], [%{label: "joy", score: 0.8}]) end)

    assert result == {:error, {:llm_run_failed, :untyped}}

    assert_received {:chain_stop, %{chain: :session_summary} = metadata}
    assert metadata.error == "{:llm_run_failed, :untyped}"

    refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ @marker
    refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ @marker
    refute log =~ @marker
  end

  test "a transport failure is a tagged reason that carries no session text" do
    attach_stop_handler()

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    {result, log} = with_log(fn -> SessionSummaryChain.run([@marker], []) end)

    assert result == {:error, {:llm_run_failed, :untyped}}
    assert_received {:chain_stop, metadata}
    refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ @marker
    refute log =~ @marker
  end

  test "run!/1 raises without the session text" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    capture_log(fn ->
      error =
        assert_raise MatchError, fn ->
          SessionSummaryChain.run!(%{sanitized_content: [@marker], emotion_scores: []})
        end

      refute Exception.message(error) =~ @marker
    end)
  end
end
