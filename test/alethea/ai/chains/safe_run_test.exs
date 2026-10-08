defmodule Alethea.AI.Chains.SafeRunTest do
  @moduledoc """
  Specifies how a `LLMChain.run/1` result becomes an application error
  (issue #402): the chain, the adapter's error text and the wrapped
  original never survive, whatever the provider put in them.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Alethea.AI.ChatModels.OllamaChat
  alias Alethea.AI.Chains.SafeRun
  alias LangChain.Chains.LLMChain
  alias LangChain.LangChainError
  alias LangChain.Message

  # A recognisable synthetic stand-in for a patient's message.
  @marker "marcador-sintetico-zzqx-saferun"

  defp chain_with_marker do
    %{llm: OllamaChat.new!(%{model: "phi4-mini", endpoint_url: "http://ollama.test:11434"})}
    |> LLMChain.new!()
    |> LLMChain.add_message(Message.new_user!(@marker))
  end

  defp printed(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  describe "normalize/1" do
    test "passes a successful run through" do
      chain = chain_with_marker()

      assert SafeRun.normalize({:ok, chain}) == {:ok, chain}
    end

    test "keeps an identifier-shaped error type and nothing else" do
      # The provider echoes the request in its message and the adapter
      # wraps the raw response: neither may survive.
      error =
        LangChainError.exception(
          type: "rate_limit_error",
          message: "Rejected request: #{@marker}",
          original: %{"body" => @marker}
        )

      result = SafeRun.normalize({:error, chain_with_marker(), error})

      assert result == {:error, {:llm_run_failed, "rate_limit_error"}}
      refute printed(result) =~ @marker
    end

    test "keeps the types LangChain itself reports" do
      for type <- ["timeout", "overloaded", "exceeded_failure_count", "invalid_json"] do
        error = LangChainError.exception(type: type, message: @marker)

        assert SafeRun.normalize({:error, chain_with_marker(), error}) ==
                 {:error, {:llm_run_failed, type}}
      end
    end

    test "an error without a type is :untyped" do
      error = LangChainError.exception(@marker)

      assert SafeRun.normalize({:error, chain_with_marker(), error}) ==
               {:error, {:llm_run_failed, :untyped}}
    end

    test "a type that could hold prose is dropped" do
      for type <- [@marker <> " with spaces", "Has Capitals", String.duplicate("a", 65), ""] do
        error = LangChainError.exception(type: type, message: "x")

        assert SafeRun.normalize({:error, chain_with_marker(), error}) ==
                 {:error, {:llm_run_failed, :unclassified}}
      end
    end

    test "a non-binary type is dropped" do
      error = %LangChainError{type: %{"detail" => @marker}, message: "x"}

      assert SafeRun.normalize({:error, chain_with_marker(), error}) ==
               {:error, {:llm_run_failed, :unclassified}}
    end

    test "a two-element error and any other shape carry no payload either" do
      assert SafeRun.normalize({:error, @marker}) == {:error, {:llm_run_failed, :unclassified}}

      assert SafeRun.normalize({:error, LangChainError.exception(type: "timeout", message: "x")}) ==
               {:error, {:llm_run_failed, "timeout"}}

      assert SafeRun.normalize({:unexpected, @marker}) ==
               {:error, {:llm_run_failed, :unclassified}}
    end
  end

  describe "run/1" do
    setup do
      Application.put_env(:alethea, :ollama_chat_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.delete_env(:alethea, :ollama_chat_req_options) end)
      :ok
    end

    test "returns the chain when the model answers" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"message" => %{"content" => "respuesta"}})
      end)

      assert {:ok, %LLMChain{last_message: %Message{content: "respuesta"}}} =
               SafeRun.run(chain_with_marker())
    end

    test "normalizes the three-element error LangChain returns" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      {result, log} = with_log(fn -> SafeRun.run(chain_with_marker()) end)

      assert result == {:error, {:llm_run_failed, :untyped}}
      refute log =~ @marker
    end

    test "an exception raised by the run is reduced to its module" do
      # An exception message can print the term that did not match, which
      # during a run is the request or the response.
      Req.Test.stub(__MODULE__, fn _conn -> raise ArgumentError, "unexpected: #{@marker}" end)

      {result, log} = with_log(fn -> SafeRun.run(chain_with_marker()) end)

      assert result == {:error, {:llm_run_failed, {:raised, ArgumentError}}}
      refute printed(result) =~ @marker
      refute log =~ @marker
    end
  end
end
