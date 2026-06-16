defmodule Alethea.Telegram.ChatIdHashTest do
  @moduledoc """
  Pure HMAC helper tests for `Alethea.Telegram.ChatIdHash`.

  Covers `REQ-C2-chat-id-stored-as-hmac` (pure half, no DB):
  - Same input + same pepper → same 64-char lowercase hex hash.
  - Different pepper → different hash.
  - Different chat_id → different hash.
  - The module is a one-way HMAC: no decoding helper is exposed.
  - The hash is NOT the raw chat_id; the chat_id cannot be recovered from
    the hash alone.
  - The hash is lower-case hex, 64 chars (256 bits).
  """

  use ExUnit.Case, async: true

  alias Alethea.Telegram.ChatIdHash

  @pepper_v1 "pepper-v1"
  @pepper_v2 "pepper-v2"
  @chat_id "123456789"
  @other_chat_id "987654321"

  describe "hash/2 — determinism and uniqueness" do
    test "same chat_id and same pepper produce the same hash" do
      assert ChatIdHash.hash(@chat_id, @pepper_v1) ==
               ChatIdHash.hash(@chat_id, @pepper_v1)
    end

    test "different chat_id and same pepper produce different hashes" do
      refute ChatIdHash.hash(@chat_id, @pepper_v1) ==
               ChatIdHash.hash(@other_chat_id, @pepper_v1)
    end

    test "same chat_id and different pepper produce different hashes" do
      refute ChatIdHash.hash(@chat_id, @pepper_v1) ==
               ChatIdHash.hash(@chat_id, @pepper_v2)
    end

    test "hash is 64 lowercase hex characters (SHA-256)" do
      hash = ChatIdHash.hash(@chat_id, @pepper_v1)

      assert byte_size(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "hash does not contain the raw chat_id as a substring" do
      hash = ChatIdHash.hash(@chat_id, @pepper_v1)

      refute String.contains?(hash, @chat_id)
    end
  end

  describe "hash/2 — known-good HMAC vector (REQ-C2 deterministic)" do
    test "matches :crypto.mac(:hmac, :sha256, pepper, chat_id) byte-for-byte" do
      # Independent reference: we recompute the same call via the crypto
      # primitive directly. This guards against a refactor that accidentally
      # uses a different algorithm or a different encoding.
      reference =
        :crypto.mac(:hmac, :sha256, @pepper_v1, @chat_id)
        |> Base.encode16(case: :lower)

      assert ChatIdHash.hash(@chat_id, @pepper_v1) == reference
    end
  end

  describe "one-way property" do
    test "module exposes no decoding helper" do
      # The module has no :decode, :unhash, :reverse, :recover, or
      # :decrypt function. This is a structural assertion enforced at compile
      # time: any future addition of a decoding helper would break this test.
      exported = ChatIdHash.__info__(:functions)

      refute Enum.any?(exported, fn {name, arity} ->
               name in [:decode, :unhash, :reverse, :recover, :decrypt] and arity >= 1
             end)
    end
  end

  describe "input coercion" do
    test "accepts integer chat_id by stringifying it before hashing" do
      # Chat ids are typically integers from Telegram; the helper must accept
      # both integer and string forms deterministically.
      assert ChatIdHash.hash(123_456_789, @pepper_v1) ==
               ChatIdHash.hash("123456789", @pepper_v1)
    end
  end
end
