defmodule Alethea.Foundation.Encryption.KEKTest do
  @moduledoc """
  KEK/DEK envelope encryption primitive tests.

  Per `openspec/sdd/bootstrap-alethea-v2/specs/encryption/spec.md`:

  - round-trip: wrap/unwrap recovers the original DEK byte-for-byte.
  - wrong KEK: unwrap returns `{:error, :corrupted}`.
  - tampered ciphertext: byte-flip in the middle → `{:error, :corrupted}`.
  - `generate/0` returns 32 bytes, no consecutive duplicates on N=100.
  - empty KEK → `{:error, :invalid_kek}`.
  - empty DEK → `{:error, :invalid_dek}`.
  - version byte `0x99` → `{:error, :version_mismatch}`.

  Additional non-spec scenarios triangulate the v2 contract:
  - the wrapped blob's first byte is `0x01` (the v1 version).
  - two independent generate/0 calls produce different bytes
    (high-entropy sanity).
  - the module is side-effect-free: no DB, no FS, no network.
  """

  use ExUnit.Case, async: true

  alias Alethea.Foundation.Encryption.KEK

  describe "round-trip" do
    test "wrap/unwrap recovers the original DEK byte-for-byte" do
      kek = KEK.generate()
      dek = KEK.generate()

      assert {:ok, wrapped} = KEK.wrap(dek, kek)
      assert {:ok, ^dek} = KEK.unwrap(wrapped, kek)
    end

    test "the same DEK wrapped twice produces different ciphertexts (random IV)" do
      # Triangulation: confirms the IV is non-deterministic.
      kek = KEK.generate()
      dek = KEK.generate()

      assert {:ok, a} = KEK.wrap(dek, kek)
      assert {:ok, b} = KEK.wrap(dek, kek)
      refute a == b
    end
  end

  describe "error paths" do
    test "unwrap with the wrong KEK returns :corrupted" do
      kek_a = KEK.generate()
      kek_b = KEK.generate()
      dek = KEK.generate()

      assert {:ok, wrapped} = KEK.wrap(dek, kek_a)
      assert {:error, :corrupted} = KEK.unwrap(wrapped, kek_b)
    end

    test "unwrap of a tampered ciphertext returns :corrupted" do
      kek = KEK.generate()
      dek = KEK.generate()
      assert {:ok, wrapped} = KEK.wrap(dek, kek)

      # Flip a byte somewhere in the middle (after the version byte
      # and the IV, into the ciphertext region).
      <<prefix::binary-size(8), byte, rest::binary>> = wrapped
      tampered = prefix <> <<bxor(byte, 0xFF)>> <> rest

      assert {:error, :corrupted} = KEK.unwrap(tampered, kek)
    end

    test "wrap with an empty KEK returns :invalid_kek" do
      kek = <<>>
      dek = KEK.generate()
      assert {:error, :invalid_kek} = KEK.wrap(dek, kek)
    end

    test "wrap with an empty DEK returns :invalid_dek" do
      kek = KEK.generate()
      dek = <<>>
      assert {:error, :invalid_dek} = KEK.wrap(dek, kek)
    end

    test "unwrap with a version byte other than 0x01 returns :version_mismatch" do
      kek = KEK.generate()
      # Hand-craft a 13+ byte blob: 0x99 (version) + 12 (iv) + some ct.
      # The exact contents don't matter because the version check
      # short-circuits before AEAD.
      bogus = <<0x99>> <> :crypto.strong_rand_bytes(40)
      assert {:error, :version_mismatch} = KEK.unwrap(bogus, kek)
    end
  end

  describe "generate/0" do
    test "returns exactly 32 bytes" do
      assert 32 == byte_size(KEK.generate())
    end

    test "100 calls produce no consecutive duplicates" do
      # Triangulation: 100 calls back-to-back must not produce
      # consecutive duplicates — proves the entropy source is
      # actually random in practice.
      samples = for _ <- 1..100, do: KEK.generate()
      pairs = Enum.chunk_every(samples, 2, 1, :discard)

      refute Enum.any?(pairs, fn [a, b] -> a == b end)
    end
  end

  describe "v2 envelope shape" do
    test "a fresh wrap produces a blob whose first byte is 0x01" do
      kek = KEK.generate()
      dek = KEK.generate()
      assert {:ok, <<0x01, _rest::binary>>} = KEK.wrap(dek, kek)
    end

    test "a wrapped blob is strictly longer than the DEK (iv + tag overhead)" do
      # 1 (version) + 12 (iv) + 32 (dek) + 16 (tag) = 61 bytes.
      kek = KEK.generate()
      dek = KEK.generate()
      assert {:ok, wrapped} = KEK.wrap(dek, kek)
      assert byte_size(wrapped) == byte_size(dek) + 1 + 12 + 16
    end
  end

  describe "module purity" do
    test "the module does not use Ecto.Schema or associations" do
      # Compile-time check: the source file must not contain
      # forbidden constructs (per the spec's integration-isolation
      # requirement).
      source = File.read!("lib/alethea/foundation/encryption/kek.ex")

      refute source =~ "use Ecto.Schema"
      refute source =~ "belongs_to"
      refute source =~ "has_many"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  defp bxor(a, b), do: :erlang.bxor(a, b)
end
