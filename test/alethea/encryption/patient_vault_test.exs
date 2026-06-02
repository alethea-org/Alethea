defmodule Alethea.Encryption.PatientVaultTest do
  use ExUnit.Case, async: true

  alias Alethea.Encryption.PatientVault
  import Bitwise

  describe "encrypt/2" do
    test "encrypts plaintext and returns ok tuple with ciphertext" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Hola, esto es un mensaje secreto"

      assert {:ok, ciphertext} = PatientVault.encrypt(plaintext, key)
      assert is_binary(ciphertext)
      assert byte_size(ciphertext) > byte_size(plaintext)
    end

    test "returns error for invalid key size" do
      key_too_short = :crypto.strong_rand_bytes(16)
      key_too_long = :crypto.strong_rand_bytes(64)

      assert {:error, _} = PatientVault.encrypt("test", key_too_short)
      assert {:error, _} = PatientVault.encrypt("test", key_too_long)
    end

    test "returns error for empty plaintext" do
      key = :crypto.strong_rand_bytes(32)
      assert {:error, _} = PatientVault.encrypt("", key)
    end
  end

  describe "decrypt/2" do
    test "roundtrip: encrypt then decrypt returns original plaintext" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Mensaje confidencial del paciente"

      {:ok, ciphertext} = PatientVault.encrypt(plaintext, key)
      {:ok, decrypted} = PatientVault.decrypt(ciphertext, key)

      assert decrypted == plaintext
    end

    test "roundtrip with unicode content" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Paciente: José María Ñoño. Dirección: Av. Principal 123, Ñuble."

      {:ok, ciphertext} = PatientVault.encrypt(plaintext, key)
      {:ok, decrypted} = PatientVault.decrypt(ciphertext, key)

      assert decrypted == plaintext
    end

    test "roundtrip with empty string" do
      key = :crypto.strong_rand_bytes(32)

      {:ok, ciphertext} = PatientVault.encrypt("", key)
      {:ok, decrypted} = PatientVault.decrypt(ciphertext, key)

      assert decrypted == ""
    end

    test "roundtrip with long text" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = String.duplicate("Lorem ipsum dolor sit amet. ", 100)

      {:ok, ciphertext} = PatientVault.encrypt(plaintext, key)
      {:ok, decrypted} = PatientVault.decrypt(ciphertext, key)

      assert decrypted == plaintext
    end

    test "roundtrip with special characters" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Test!@#$%^&*()_+-=[]{}|;':\",./<>?`~\n\t\r"

      {:ok, ciphertext} = PatientVault.encrypt(plaintext, key)
      {:ok, decrypted} = PatientVault.decrypt(ciphertext, key)

      assert decrypted == plaintext
    end

    test "returns error for tampered ciphertext" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Mensaje original"

      {:ok, ciphertext} = PatientVault.encrypt(plaintext, key)
      # Tamper with the ciphertext (flip a byte in the middle)
      tampered = flip_byte_in_middle(ciphertext)

      assert {:error, :decryption_failed} = PatientVault.decrypt(tampered, key)
    end

    test "returns error for wrong key" do
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)
      plaintext = "Mensaje secreto"

      {:ok, ciphertext} = PatientVault.encrypt(plaintext, key1)
      assert {:error, :decryption_failed} = PatientVault.decrypt(ciphertext, key2)
    end

    test "returns error for invalid ciphertext format" do
      key = :crypto.strong_rand_bytes(32)

      assert {:error, :invalid_ciphertext} = PatientVault.decrypt("too_short", key)
      assert {:error, :invalid_ciphertext} = PatientVault.decrypt(<<>>, key)
      assert {:error, :invalid_ciphertext} = PatientVault.decrypt(nil, key)
    end
  end

  describe "security properties" do
    test "same plaintext produces different ciphertext each time (IV randomness)" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "Mensaje constante"

      {:ok, ciphertext1} = PatientVault.encrypt(plaintext, key)
      {:ok, ciphertext2} = PatientVault.encrypt(plaintext, key)

      refute ciphertext1 == ciphertext2
    end

    test "IV is exactly 12 bytes" do
      key = :crypto.strong_rand_bytes(32)
      {:ok, ciphertext} = PatientVault.encrypt("test", key)

      iv = binary_part(ciphertext, 0, 12)
      assert byte_size(iv) == 12
    end

    test "tag is exactly 16 bytes" do
      key = :crypto.strong_rand_bytes(32)
      {:ok, ciphertext} = PatientVault.encrypt("test", key)

      total_size = byte_size(ciphertext)
      tag = binary_part(ciphertext, total_size - 16, 16)
      assert byte_size(tag) == 16
    end
  end

  # Helper: flip one byte in the middle of the ciphertext
  defp flip_byte_in_middle(binary) do
    mid = div(byte_size(binary), 2)
    <<front::binary-size(mid), byte, back::binary>> = binary
    flipped_byte = bxor(byte, 0xFF)
    <<front::binary, flipped_byte, back::binary>>
  end
end
