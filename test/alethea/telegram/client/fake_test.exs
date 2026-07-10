defmodule Alethea.Telegram.Client.FakeTest do
  @moduledoc """
  Tests for the `Alethea.Telegram.Client.Fake` test/dev adapter.

  The Fake is a `GenServer` that owns an ETS table and serialises
  every `send_message/2` call through that table. The tests verify
  the accumulator + reset contract; PR #3a's `TelegramOutboundWorker`
  tests will use this adapter via `Application.put_env` and assert
  on `Fake.sends/0` to verify the worker called `send_message/2`
  with the right arguments.
  """

  use ExUnit.Case

  alias Alethea.Telegram.Client.Fake

  setup do
    # Start the Fake per test (the production Application does not
    # start it — the Fake is consumed by tests directly or by the
    # outbound worker via the `:telegram_client` config).
    start_supervised!(Fake)
    Fake.reset()
    :ok
  end

  describe "@impl Client.send_message/2" do
    test "returns {:ok, id} with a unique positive-integer id per call" do
      assert {:ok, id1} = Fake.send_message(987_654, "hello")
      assert {:ok, id2} = Fake.send_message(987_654, "hello again")
      assert is_integer(id1) and id1 > 0
      assert is_integer(id2) and id2 > 0
      assert id1 != id2
    end

    test "appends to the sends list (does not overwrite)" do
      Fake.send_message(111, "first")
      Fake.send_message(222, "second")
      Fake.send_message(333, "third")

      sends = Fake.sends()
      assert length(sends) == 3

      # The underlying ETS is a `:set` (keyed by `message_id`, not
      # insertion order) so we look up each send by `chat_id`.
      assert Enum.find(sends, &(&1.chat_id == 111)).text == "first"
      assert Enum.find(sends, &(&1.chat_id == 222)).text == "second"
      assert Enum.find(sends, &(&1.chat_id == 333)).text == "third"
    end

    test "preserves the chat_id and text exactly (no transformation at the adapter layer)" do
      text = "hola, hoy fue un día difícil"
      Fake.send_message(987_654, text)

      [send] = Fake.sends()
      assert send.chat_id == 987_654
      assert send.text == text
    end
  end

  describe "Fake.sends/0 + Fake.reset/0" do
    test "sends/0 returns an empty list when no sends have been recorded" do
      assert Fake.sends() == []
    end

    test "reset/0 clears the recorded sends" do
      Fake.send_message(1, "a")
      Fake.send_message(2, "b")
      assert length(Fake.sends()) == 2

      assert :ok = Fake.reset()
      assert Fake.sends() == []
    end
  end

  describe "defensive guards" do
    test "send_message/2 raises on a non-positive-integer chat_id" do
      assert_raise ArgumentError, fn ->
        Fake.send_message(0, "hello")
      end

      assert_raise ArgumentError, fn ->
        Fake.send_message(-1, "hello")
      end
    end

    test "send_message/2 raises on a non-binary text" do
      assert_raise ArgumentError, fn ->
        Fake.send_message(1, 123)
      end

      assert_raise ArgumentError, fn ->
        Fake.send_message(1, nil)
      end
    end
  end
end
