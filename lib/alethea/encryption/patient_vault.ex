defmodule Alethea.Encryption.PatientVault do
  @moduledoc """
  Provee funciones de cifrado y descifrado para datos de pacientes
  utilizando AES-256-GCM con IV aleatorio prefijado.
  """

  @aad "alethea-patient-data"
  @iv_length 12
  @tag_length 16

  @doc """
  Cifra un texto plano utilizando una clave (DEK o KEK).
  Retorna el binario con el IV prefijado: [IV (12 bytes)][Ciphertext][Tag (16 bytes)]
  """
  def encrypt(_, key) when byte_size(key) != 32,
    do: {:error, :invalid_key_size}

  def encrypt("", _key),
    do: {:error, :empty_plaintext}

  def encrypt(plaintext, key) when byte_size(key) == 32 do
    iv = :crypto.strong_rand_bytes(@iv_length)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    {:ok, iv <> ciphertext <> tag}
  rescue
    _ -> {:error, :encryption_failed}
  end

  @doc """
  Descifra un binario cifrado (con IV prefijado) utilizando una clave.
  """
  def decrypt(_, key) when byte_size(key) != 32,
    do: {:error, :invalid_key_size}

  def decrypt(<<iv::binary-size(@iv_length), rest::binary>>, key) when byte_size(key) == 32 do
    ciphertext_length = byte_size(rest) - @tag_length
    <<ciphertext::binary-size(^ciphertext_length), tag::binary-size(@tag_length)>> = rest

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  rescue
    _ -> {:error, :decryption_failed}
  end

  def decrypt(_, _), do: {:error, :invalid_ciphertext}
end
