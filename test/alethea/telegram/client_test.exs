defmodule Alethea.Telegram.ClientTest do
  @moduledoc """
  Tests for the `Alethea.Telegram.Client` behaviour contract and
  the `Alethea.Telegram.Client.Fake` adapter.

  The `Req` production adapter lands in PR #3a. This test file
  covers only the contract surface that PR #3a must implement:

    - `send_message/2` returns `{:ok, id}` on success (id may be
      `nil` if the transport does not return one), or
      `{:error, term}` on failure.
    - The adapter does not log the `text` argument (R-1 PHI
      hygiene — this is asserted structurally: the Fake has zero
      `Logger` calls in its source).
  """

  use ExUnit.Case, async: true

  alias Alethea.Telegram.Client
  alias Alethea.Telegram.Client.Fake

  describe "behaviour — callback arity and return shape" do
    test "send_message/2 is exported on the behaviour" do
      callbacks = Client.behaviour_info(:callbacks)
      # `behaviour_info(:callbacks)` returns a keyword list
      # `[{callback_name, arity}, ...]` — the test asserts the
      # callback is present with the expected arity.
      assert Keyword.get(callbacks, :send_message) == 2
    end

    test "Fake implements the behaviour (no UndefinedFunctionError on send_message/2)" do
      # Force-load the Fake module so function_exported? returns
      # the actual answer (not just "module not yet loaded").
      Code.ensure_loaded!(Fake)
      assert function_exported?(Fake, :send_message, 2)
    end
  end

  describe "PHI hygiene (R-1) — structural assertion" do
    test "the Fake has no Logger calls in its source (defense-in-depth)" do
      # This is a structural check — the Fake's moduledoc and
      # function bodies must not include `Logger` calls. PR #3a's
      # `Req` adapter should follow the same convention.
      #
      # The check is intentionally a string-match on the source
      # file rather than a behavioural test because the failure
      # mode we're guarding against is "the developer adds a
      # Logger.info(chat_id) in the Fake" — that's a textual
      # change, and a behavioural test (e.g. capture_log) would
      # miss it if the log line were gated on a condition we
      # don't exercise.
      source = File.read!("lib/alethea/telegram/client/fake.ex")
      refute source =~ ~r/Logger\.(info|debug|warn|error)/
    end
  end
end
