defmodule Alethea.AI.RetryTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.Retry

  describe "struct" do
    test "has correct default values" do
      retry = %Retry{}
      assert retry.max_attempts == 3
      assert retry.base_delay_ms == 1_000
      assert retry.max_delay_ms == 30_000
      assert retry.attempts == 0
      assert retry.circuit_open == false
    end

    test "can be customized" do
      retry = %Retry{max_attempts: 5, base_delay_ms: 500}
      assert retry.max_attempts == 5
      assert retry.base_delay_ms == 500
    end
  end

  describe "with_retry/2" do
    test "returns success when function succeeds" do
      retry = %Retry{max_attempts: 3}
      result = Retry.with_retry(retry, fn -> {:ok, "success"} end)
      assert {:ok, "success"} = result
    end

    test "returns function error when not retryable" do
      retry = %Retry{max_attempts: 3}
      result = Retry.with_retry(retry, fn -> raise "not a LangChainError" end)
      assert {:error, "not a LangChainError"} = result
    end

    test "respects max_attempts limit" do
      retry = %Retry{max_attempts: 1}

      result =
        Retry.with_retry(retry, fn ->
          raise %LangChain.LangChainError{message: "model is loading (503)"}
        end)

      # Should fail after 1 attempt (max_attempts)
      assert {:error, :model_loading} = result
    end
  end

  describe "default/0" do
    test "returns struct with sensible defaults" do
      retry = Retry.default()
      assert retry.max_attempts == 3
      assert retry.base_delay_ms == 1_000
      assert retry.retryable_errors == [:model_loading, :timeout, :rate_limit]
    end
  end

  describe "production/0" do
    test "returns more aggressive config" do
      retry = Retry.production()
      assert retry.max_attempts == 5
      assert retry.base_delay_ms == 2_000
      assert retry.max_delay_ms == 60_000
      assert :connection_error in retry.retryable_errors
    end
  end

  describe "retry classification" do
    test "recognizes model loading errors" do
      retry = %Retry{max_attempts: 3}
      assert retry.retryable_errors == [:model_loading, :timeout, :rate_limit]
    end
  end
end
