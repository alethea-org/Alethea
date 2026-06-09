defmodule Alethea.AI.Mock.RoBERTaTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.Mock.RoBERTa

  setup do
    # Start mock if not running
    case GenServer.start(RoBERTa, [], name: RoBERTa) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Reset state
    GenServer.call(RoBERTa, :reset)
    {:ok, %{}}
  end

  describe "set_response/1" do
    test "configures a single response" do
      response = [
        %{predictions: [%{label: "joy", score: 0.85}]},
        %{predictions: [%{label: "sadness", score: 0.60}]}
      ]

      assert RoBERTa.set_response(response) == :ok
      assert RoBERTa.analyze_batch(["text"]) == response
    end

    test "configures map response" do
      response = %{predictions: [%{label: "joy", score: 0.95}]}
      RoBERTa.set_response(response)
      assert RoBERTa.analyze_batch([]) == response
    end
  end

  describe "set_responses/1" do
    test "returns responses in sequence" do
      RoBERTa.set_responses([
        [%{predictions: [%{label: "joy", score: 0.8}]}],
        [%{predictions: [%{label: "sadness", score: 0.7}]}]
      ])

      assert RoBERTa.analyze_batch(["text1"]) == [%{predictions: [%{label: "joy", score: 0.8}]}]

      assert RoBERTa.analyze_batch(["text2"]) == [
               %{predictions: [%{label: "sadness", score: 0.7}]}
             ]
    end

    test "exhausts sequence and returns last response" do
      RoBERTa.set_responses([[%{predictions: [%{label: "joy", score: 0.8}]}]])
      assert RoBERTa.analyze_batch(["t1"]) == [%{predictions: [%{label: "joy", score: 0.8}]}]
      assert RoBERTa.analyze_batch(["t2"]) == [%{predictions: [%{label: "joy", score: 0.8}]}]
    end
  end

  describe "set_error/2" do
    test "returns timeout error" do
      RoBERTa.set_error(:timeout, "Connection timed out")
      result = RoBERTa.analyze_batch(["text"])
      assert result == {:error, %{type: :timeout, message: "Connection timed out"}}
    end

    test "returns rate limit error" do
      RoBERTa.set_error(:rate_limit, "Rate limit exceeded")
      result = RoBERTa.analyze_batch(["text"])
      assert result == {:error, %{type: :rate_limit, message: "Rate limit exceeded"}}
    end

    test "returns api error" do
      RoBERTa.set_error(:api_error, "Invalid API key")
      result = RoBERTa.analyze_batch(["text"])
      assert result == {:error, %{type: :api_error, message: "Invalid API key"}}
    end
  end

  describe "call tracking" do
    test "tracks calls to analyze_batch" do
      RoBERTa.set_response([%{predictions: [%{label: "joy", score: 0.8}]}])

      RoBERTa.analyze_batch(["text1"])
      RoBERTa.analyze_batch(["text2"])

      calls = RoBERTa.get_calls()
      assert length(calls) == 2
      assert Enum.at(calls, 0).args == ["text1"]
      assert Enum.at(calls, 1).args == ["text2"]
    end

    test "call_count returns correct number" do
      RoBERTa.set_response([%{predictions: [%{label: "joy", score: 0.8}]}])

      RoBERTa.analyze_batch(["t1"])
      RoBERTa.analyze_batch(["t2"])
      RoBERTa.analyze_batch(["t3"])

      assert RoBERTa.call_count() == 3
    end

    test "was_called? returns true when called" do
      RoBERTa.set_response([%{predictions: [%{label: "joy", score: 0.8}]}])
      RoBERTa.analyze_batch(["text"])

      assert RoBERTa.was_called?() == true
    end

    test "was_called? returns false when not called" do
      RoBERTa.reset()
      assert RoBERTa.was_called?() == false
    end
  end

  describe "reset/0" do
    test "clears response and calls" do
      RoBERTa.set_response([%{predictions: [%{label: "joy", score: 0.8}]}])
      RoBERTa.analyze_batch(["text"])

      RoBERTa.reset()

      assert RoBERTa.get_calls() == []
      assert RoBERTa.was_called?() == false
    end
  end
end

defmodule Alethea.AI.Mock.PhiTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.Mock.Phi

  setup do
    case GenServer.start(Phi, [], name: Phi) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    GenServer.call(Phi, :reset)
    {:ok, %{}}
  end

  describe "set_response/1" do
    test "configures a success response" do
      response = {:ok, %{content: "Buenos días", done: true}}
      assert Phi.set_response(response) == :ok
      assert Phi.process(%{message_id: "123"}) == {:ok, %{content: "Buenos días", done: true}}
    end

    test "configures an error response" do
      response = {:error, %{type: :validation_error, message: "Invalid input"}}
      Phi.set_response(response)

      assert Phi.process(%{message_id: "123"}) ==
               {:error, %{type: :validation_error, message: "Invalid input"}}
    end
  end

  describe "set_responses/1" do
    test "returns responses in sequence" do
      responses = [
        {:ok, %{content: "First response"}},
        {:ok, %{content: "Second response"}}
      ]

      Phi.set_responses(responses)

      assert Phi.process(%{message_id: "1"}) == {:ok, %{content: "First response"}}
      assert Phi.process(%{message_id: "2"}) == {:ok, %{content: "Second response"}}
    end
  end

  describe "set_error/2" do
    test "returns timeout error" do
      Phi.set_error(:timeout, "Connection timed out")
      result = Phi.process(%{message_id: "123"})
      assert result == {:error, %{type: :timeout, message: "Connection timed out"}}
    end

    test "returns rate limit error" do
      Phi.set_error(:rate_limit, "Rate limit exceeded")
      result = Phi.process(%{message_id: "123"})
      assert result == {:error, %{type: :rate_limit, message: "Rate limit exceeded"}}
    end

    test "returns api error" do
      Phi.set_error(:api_error, "Service unavailable")
      result = Phi.process(%{message_id: "123"})
      assert result == {:error, %{type: :api_error, message: "Service unavailable"}}
    end

    test "returns sanitization error" do
      Phi.set_error(:sanitization_error, "Invalid characters")
      result = Phi.process(%{message_id: "123"})
      assert result == {:error, %{type: :sanitization_error, message: "Invalid characters"}}
    end
  end

  describe "call tracking" do
    test "tracks calls to process" do
      Phi.set_response({:ok, %{content: "test"}})
      Phi.process(%{message_id: "msg_1", raw_content: "content1"})
      Phi.process(%{message_id: "msg_2", raw_content: "content2"})

      calls = Phi.get_calls()
      assert length(calls) == 2
      assert Enum.at(calls, 0).args.message_id == "msg_1"
      assert Enum.at(calls, 1).args.message_id == "msg_2"
    end

    test "call_count returns correct number" do
      Phi.set_response({:ok, %{content: "test"}})
      Phi.process(%{message_id: "1"})
      Phi.process(%{message_id: "2"})
      assert Phi.call_count() == 2
    end
  end

  describe "reset/0" do
    test "clears state" do
      Phi.set_response({:ok, %{content: "test"}})
      Phi.process(%{message_id: "123"})
      Phi.reset()
      assert Phi.get_calls() == []
      assert Phi.call_count() == 0
    end
  end
end

defmodule Alethea.AI.MockCaseTest do
  use ExUnit.Case, async: false

  import Alethea.AI.MockCase

  alias Alethea.AI.Mock.RoBERTa

  setup do
    case GenServer.start(RoBERTa, [], name: RoBERTa) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    GenServer.call(RoBERTa, :reset)
    {:ok, %{}}
  end

  describe "mock_roberta/1" do
    test "configures response via MockCase helper" do
      response = [%{predictions: [%{label: "joy", score: 0.9}]}]
      mock_roberta(response)
      assert RoBERTa.analyze_batch(["text"]) == response
    end
  end

  describe "mock_roberta_error/2" do
    test "configures error via MockCase helper" do
      mock_roberta_error(:timeout, "Test timeout")

      result = RoBERTa.analyze_batch(["text"])
      assert result == {:error, %{type: :timeout, message: "Test timeout"}}
    end
  end

  describe "assert_roberta_called/1" do
    test "asserts mock was called with specific args" do
      RoBERTa.set_response([%{predictions: [%{label: "joy", score: 0.8}]}])
      RoBERTa.analyze_batch(["hello world"])

      assert_roberta_called(%{args: ["hello world"]})
    end

    test "fails when mock was not called" do
      RoBERTa.reset()

      assert_raise ExUnit.AssertionError, fn ->
        assert_roberta_called(%{args: ["something"]})
      end
    end
  end
end
