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
