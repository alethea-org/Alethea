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

  # F-03: pin the moduledoc/function-head examples to the real impl.
  # A regression in `hash/2` (algorithm swap, encoding change) would
  # be caught by the doctest because the example output would no
  # longer match the real HMAC-SHA256 output.
  doctest Alethea.Telegram.ChatIdHash

  # F-01: peppers MUST be at least 32 bytes (HMAC-SHA256 with a
  # 0-byte or short key is cryptographically weak). The test peppers
  # are 32-byte ASCII strings.
  @pepper_v1 "pepper-v1-32-bytes-min-len-padding-pad"
  @pepper_v2 "pepper-v2-32-bytes-min-len-padding-pad"
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

  describe "hash/2 — pepper length guard (F-01)" do
    test "raises ArgumentError when pepper is shorter than 32 bytes" do
      # HMAC-SHA256 with a 0-byte or short key is cryptographically
      # weak. The function MUST refuse to operate below 32 bytes of
      # key material — silently accepting a short pepper is the
      # crypto-equivalent of a `==` typo. Test: the empty string is
      # the worst case (0 bytes).
      assert_raise ArgumentError, ~r/pepper must be at least 32 bytes/, fn ->
        ChatIdHash.hash(@chat_id, "")
      end
    end

    test "raises ArgumentError when pepper is exactly 31 bytes (boundary)" do
      # Boundary case: 31 bytes is one short of the minimum. The guard
      # must catch it (not round up, not silently truncate).
      short = String.duplicate("a", 31)

      assert_raise ArgumentError, ~r/pepper must be at least 32 bytes/, fn ->
        ChatIdHash.hash(@chat_id, short)
      end
    end

    test "accepts a pepper of exactly 32 bytes (boundary)" do
      # Boundary case: 32 bytes is the minimum. The guard must NOT
      # reject it. The function returns a 64-char hash.
      min_pepper = String.duplicate("a", 32)
      hash = ChatIdHash.hash(@chat_id, min_pepper)

      assert byte_size(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "hash/2 — chat_id type guard (F-02)" do
    test "raises ArgumentError when chat_id is an atom" do
      # Telegram chat ids are integers (or strings of digits). Atoms,
      # floats, structs, maps, lists, and tuples are silently
      # stringified by `to_string/1` but produce a hash that is
      # nonsensical as a lookup key. The function MUST refuse
      # non-canonical inputs.
      assert_raise ArgumentError, ~r/chat_id must be an integer or a string/, fn ->
        ChatIdHash.hash(:not_a_chat_id, @pepper_v1)
      end
    end

    test "raises ArgumentError when chat_id is a float" do
      assert_raise ArgumentError, ~r/chat_id must be an integer or a string/, fn ->
        ChatIdHash.hash(123_456_789.0, @pepper_v1)
      end
    end

    test "raises ArgumentError when chat_id is a struct" do
      # %Date{} is a struct; the guard MUST catch it. The original
      # implementation stringified structs silently via `to_string/1`,
      # producing a hash that has no canonical interpretation as a
      # chat_id lookup key.
      assert_raise ArgumentError, ~r/chat_id must be an integer or a string/, fn ->
        ChatIdHash.hash(~D[2026-06-17], @pepper_v1)
      end
    end

    test "raises ArgumentError when chat_id is a map" do
      assert_raise ArgumentError, ~r/chat_id must be an integer or a string/, fn ->
        ChatIdHash.hash(%{id: 123_456_789}, @pepper_v1)
      end
    end

    test "raises ArgumentError when chat_id is a list" do
      assert_raise ArgumentError, ~r/chat_id must be an integer or a string/, fn ->
        ChatIdHash.hash([1, 2, 3, 4, 5, 6, 7, 8, 9], @pepper_v1)
      end
    end

    test "raises ArgumentError when chat_id is nil" do
      assert_raise ArgumentError, ~r/chat_id must be an integer or a string/, fn ->
        ChatIdHash.hash(nil, @pepper_v1)
      end
    end
  end
end
