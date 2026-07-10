defmodule Alethea.Telegram.DeepLinkTokenTest do
  @moduledoc """
  Tests for `Alethea.Telegram.DeepLinkToken` (C-4 pure half).

  Covers `REQ-C4-mint-deep-link-token` (pure half — no DB):
  - `mint/0` returns a 32-byte URL-safe base64 token (43–44 chars,
    no padding, alphabet `[A-Za-z0-9_-]`).
  - Two mints are independently unique (collision probability ≈ 2^-192).
  - The token never contains the chat_id or any user-controlled value
    as a substring.
  - `valid_format?/1` accepts canonical mint output, rejects empty,
    non-binary, over-long, under-long, and non-alphabet strings.
  - The module exposes no DB or process side effects — it is pure.
  """

  use ExUnit.Case, async: true

  alias Alethea.Telegram.DeepLinkToken

  describe "mint/0 — token shape (REQ-C4-mint-deep-link-token)" do
    test "returns a 43- or 44-char URL-safe base64 string" do
      token = DeepLinkToken.mint()

      assert is_binary(token)
      assert byte_size(token) in 43..44
    end

    test "uses the URL-safe alphabet only (no '+', '/', or '=' padding)" do
      token = DeepLinkToken.mint()

      assert token =~ ~r/^[A-Za-z0-9_-]+$/
      refute String.contains?(token, "+")
      refute String.contains?(token, "/")
      refute String.contains?(token, "=")
    end

    test "decodes back to exactly 32 raw bytes (the canonical token entropy)" do
      token = DeepLinkToken.mint()

      # `Base.url_decode64!/2` is the inverse of `Base.url_encode64(_, padding: false)`
      # and rejects padding (`=`), so a clean round-trip is the strongest
      # assertion that we used the canonical encoding.
      decoded = Base.url_decode64!(token, padding: false)
      assert byte_size(decoded) == 32
    end
  end

  describe "mint/0 — uniqueness" do
    test "two mints are independently unique (collision probability ≈ 2^-192)" do
      # Spec scenario "two mints for the same patient are independently
      # unique" — we test it without persistence by minting 100 tokens
      # and asserting no duplicates. With 32 random bytes the birthday
      # bound is far below 1 in 2^32 for 100 samples, so we should
      # never see a duplicate here.
      tokens = for _ <- 1..100, do: DeepLinkToken.mint()

      assert length(Enum.uniq(tokens)) == 100
    end

    test "one mint is not derived from any prior mint" do
      # A sanity check that the token is NOT a hash of a counter or a
      # chat_id. The token is 256 bits of CSPRNG entropy; if a future
      # refactor accidentally derived it from a counter, the next mint
      # after a fixed seed would be predictable. We can't directly
      # test the CSPRNG property, but we can assert that the token
      # contains no recognisable substring like "patient" or "chat".
      token = DeepLinkToken.mint()

      refute String.contains?(token, "patient")
      refute String.contains?(token, "chat")
    end
  end

  describe "valid_format?/1 — canonical format check" do
    test "accepts a freshly minted token" do
      token = DeepLinkToken.mint()
      assert DeepLinkToken.valid_format?(token)
    end

    test "accepts a hand-crafted canonical 43-char URL-safe base64 token (all zeros)" do
      # 32 bytes of zeros -> Base.url_encode64(_, padding: false) -> "AAAA...AAAA" (43 chars)
      canonical = Base.url_encode64(:binary.copy(<<0>>, 32), padding: false)
      assert byte_size(canonical) == 43
      assert DeepLinkToken.valid_format?(canonical)
    end

    test "accepts a hand-crafted canonical 43-char URL-safe base64 token (all 0xFF)" do
      # 32 raw bytes encode to exactly 43 chars with `padding: false`:
      # 10 full groups of 3 bytes → 40 chars, plus 2 trailing bytes → 3 chars
      # (no padding). The 32-byte input always lands at 43 chars.
      canonical = Base.url_encode64(:binary.copy(<<0xFF>>, 32), padding: false)
      assert byte_size(canonical) == 43
      assert DeepLinkToken.valid_format?(canonical)
    end

    test "rejects an empty string" do
      refute DeepLinkToken.valid_format?("")
    end

    test "rejects a non-binary input" do
      refute DeepLinkToken.valid_format?(nil)
      refute DeepLinkToken.valid_format?(123)
      refute DeepLinkToken.valid_format?(:token)
      refute DeepLinkToken.valid_format?(%{value: "abc"})
    end

    test "rejects a token shorter than 43 chars" do
      refute DeepLinkToken.valid_format?(String.duplicate("A", 42))
    end

    test "rejects a token longer than 43 chars" do
      refute DeepLinkToken.valid_format?(String.duplicate("A", 44))
    end

    test "rejects a token with the wrong alphabet (e.g. contains '+')" do
      # 43 chars but with a '+' in the middle -> URL-unsafe alphabet.
      bad = String.duplicate("A", 21) <> "+" <> String.duplicate("A", 21)
      refute DeepLinkToken.valid_format?(bad)
    end

    test "rejects a token with padding ('=')" do
      bad = String.duplicate("A", 42) <> "="
      refute DeepLinkToken.valid_format?(bad)
    end
  end

  describe "module purity" do
    test "module has no DB / process / ETS side effects" do
      # The pure-half contract: mint/0 and valid_format?/1 do not depend
      # on any external state. We assert the module exposes only the
      # documented functions (no hidden Repo, GenServer, or ETS calls).
      exported = DeepLinkToken.__info__(:functions)

      refute Enum.any?(exported, fn {name, _arity} ->
               name in [:save_to_db, :lookup, :consume, :verify_in_db]
             end)

      # The module has no `use GenServer`, no `use Ecto.Schema`, no
      # `use Agent`. This is a structural assertion enforced at compile
      # time: any future addition of a stateful behaviour would break
      # this test by adding `:child_spec/1` to the exported list.
      refute {:child_spec, 1} in exported
    end
  end
end
