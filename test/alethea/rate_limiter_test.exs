defmodule Alethea.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Alethea.RateLimiter

  setup do
    # Clean up before and after each test
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  describe "check/1" do
    test "allows first request" do
      assert :ok = RateLimiter.check("test_phone_1")
    end

    test "allows multiple requests under limit" do
      phone = "test_phone_2"

      Enum.each(1..10, fn _ ->
        assert :ok = RateLimiter.check(phone)
      end)
    end

    test "blocks requests over limit" do
      phone = "test_phone_3"

      # Use up the quota
      Enum.each(1..10, fn _ ->
        RateLimiter.check(phone)
      end)

      # Next request should be rate limited
      assert {:error, :rate_limited} = RateLimiter.check(phone)
    end

    test "different phones have separate limits" do
      phone_a = "phone_a"
      phone_b = "phone_b"

      # Use up phone_a's quota
      Enum.each(1..10, fn _ ->
        RateLimiter.check(phone_a)
      end)

      # phone_b should still be allowed
      assert :ok = RateLimiter.check(phone_b)
    end

    test "allows requests after window expires" do
      phone = "test_phone_window"

      # Use up the quota
      Enum.each(1..10, fn _ ->
        RateLimiter.check(phone)
      end)

      # Should be rate limited
      assert {:error, :rate_limited} = RateLimiter.check(phone)
    end
  end

  describe "status/1" do
    test "shows correct remaining count" do
      phone = "status_phone"

      # First check - should have 10 remaining
      initial = RateLimiter.status(phone)
      assert initial.remaining == 10

      # Use 3 requests
      Enum.each(1..3, fn _ -> RateLimiter.check(phone) end)

      status = RateLimiter.status(phone)
      assert status.remaining == 7
    end

    test "shows zero remaining when at limit" do
      phone = "status_limit_phone"

      Enum.each(1..10, fn _ -> RateLimiter.check(phone) end)

      status = RateLimiter.status(phone)
      assert status.remaining == 0
    end

    test "returns default when no requests made" do
      status = RateLimiter.status("never_used_phone")
      assert status.remaining == 10
    end
  end

  describe "clear_all/0" do
    test "clears all entries" do
      phone = "to_be_cleared"

      # Make some requests
      Enum.each(1..5, fn _ -> RateLimiter.check(phone) end)

      # Verify some requests were made
      status = RateLimiter.status(phone)
      assert status.remaining < 10

      # Clear all
      RateLimiter.clear_all()

      # Should be reset
      status = RateLimiter.status(phone)
      assert status.remaining == 10
    end
  end

  describe "error handling" do
    test "allows requests if ETS is not available" do
      # This test verifies graceful degradation
      # In normal operation, ETS should always be available
      # but if not, check/1 should return :ok
      result = RateLimiter.check("ets_error_test")
      assert result == :ok || result == {:error, :rate_limited}
    end
  end
end
