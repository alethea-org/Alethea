defmodule Alethea.Foundation.Encryption.KEK do
  @moduledoc """
  KEK/DEK envelope encryption primitive — v2 contract.

  This is the v2 crypto primitive for wrapping DEKs (data encryption
  keys) with KEKs (key encryption keys), enabling **cryptographic
  erasure** (per `UBIQUITOUS_LANGUAGE.md`): destroying the DEK record
  makes the patient's encrypted data irrecoverable.

  ## Wire format

  A wrapped DEK is a binary of the shape:

      <<version :: 1-byte,
        iv      :: 12-bytes,
        ct      :: binary,   # length == byte_size(dek)
        tag     :: 16-bytes>>

  The current `version` is `0x01`. Future rotations (e.g., a `0x02`
  envelope with a different cipher) will increment this byte; the
  `unwrap/2` function rejects unknown versions with
  `{:error, :version_mismatch}`.

  ## Wire-incompatibility with legacy `Alethea.Encryption.PatientVault`

  The legacy `Alethea.Encryption.PatientVault` (in
  `lib/alethea/encryption/patient_vault.ex`) uses a similar but
  **deliberately incompatible** envelope:

  - Legacy shape:  `<<iv::12-bytes, ct, tag::16-bytes>>` (no version).
  - Legacy AAD:    `"alethea-patient-data"`.
  - Legacy API:    `encrypt/2`, `decrypt/2`; errors are
                   `:invalid_key_size`, `:empty_plaintext`,
                   `:decryption_failed`.

  This v2 module uses:

  - v2 shape:      `<<0x01, iv::12-bytes, ct, tag::16-bytes>>`.
  - v2 AAD:        `"alethea-foundation-kek-v1"`.
  - v2 API:        `generate/0`, `wrap/2`, `unwrap/2`; errors are
                   `:invalid_kek`, `:invalid_dek`, `:corrupted`,
                   `:version_mismatch`.

  A blob produced by the legacy `PatientVault.encrypt/2` will be
  rejected by `unwrap/2` with `{:error, :version_mismatch}` (its
  first byte is part of the IV, not `0x01`), and vice versa. **Do
  not** route legacy ciphertexts through this module — that is the
  job of a future migration change.

  ## Side-effect-free

  This module does not read `Application.get_env` for any value
  other than what is set in tests via the configuration. It does
  not persist keys, does not depend on Ecto, and does not import
  any submodule of `Alethea.Accounts`. The `generate/0` function is
  the only way to create a key.

  ## Integration

  This module is NOT wired into any schema or any `Alethea.Accounts`
  function. Wiring is the job of a future `encryption-integration-foundation`
  change. The `psicologo-foundation` change is the most likely
  integration point (per-patient DEK, per-tenant KEK).
  """

  @aad "alethea-foundation-kek-v1"
  @iv_length 12
  @tag_length 16
  @key_length 32
  @version_v1 0x01

  @typedoc "Data Encryption Key. 32 raw bytes of high-entropy data."
  @type dek :: binary()

  @typedoc "Key Encryption Key. 32 raw bytes of high-entropy data."
  @type kek :: binary()

  @doc """
  Generates a fresh 32-byte key suitable for use as a KEK or a DEK.

  Uses `:crypto.strong_rand_bytes/1`, which on Linux reads from
  `/dev/urandom` and on macOS reads from `SecRandomCopyBytes`. The
  output MUST NOT be persisted in plaintext; wrap it with a higher-
  level key (or with `Alethea.Encryption.Vault` for storage).
  """
  @spec generate() :: kek()
  def generate do
    :crypto.strong_rand_bytes(@key_length)
  end

  @doc """
  Wraps a DEK with a KEK, returning a self-describing versioned envelope.

  The envelope's first byte is the version (`0x01` for this implementation).
  The IV is randomly generated per call, so the same DEK wrapped twice
  with the same KEK produces different ciphertexts.

  Returns `{:error, :invalid_kek}` if the KEK is not exactly 32 bytes
  (including the empty-binary case), and `{:error, :invalid_dek}` if
  the DEK is not exactly 32 bytes.
  """
  @spec wrap(dek(), kek()) ::
          {:ok, wrapped :: binary()}
          | {:error, :invalid_kek | :invalid_dek}
  def wrap(dek, kek) when byte_size(kek) != @key_length, do: {:error, :invalid_kek}
  def wrap(dek, kek) when byte_size(dek) != @key_length, do: {:error, :invalid_dek}

  def wrap(dek, kek) do
    iv = :crypto.strong_rand_bytes(@iv_length)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, dek, @aad, true)

    wrapped = <<@version_v1>> <> iv <> ciphertext <> tag
    {:ok, wrapped}
  rescue
    _ -> {:error, :corrupted}
  end

  @doc """
  Unwraps a wrapped DEK, returning the original plaintext DEK.

  Rejects:
  - `{:error, :invalid_kek}` — the KEK is not exactly 32 bytes.
  - `{:error, :corrupted}` — the AEAD tag verification fails (wrong
    KEK, tampered ciphertext, truncated blob).
  - `{:error, :version_mismatch}` — the version byte is not `0x01`.

  Returns `{:ok, dek}` on success.
  """
  @spec unwrap(wrapped :: binary(), kek()) ::
          {:ok, dek()}
          | {:error, :invalid_kek | :corrupted | :version_mismatch}
  def unwrap(_wrapped, kek) when byte_size(kek) != @key_length, do: {:error, :invalid_kek}

  def unwrap(<<@version_v1, iv::binary-size(@iv_length), rest::binary>>, kek) do
    ciphertext_length = byte_size(rest) - @tag_length
    <<ciphertext::binary-size(ciphertext_length), tag::binary-size(@tag_length)>> = rest

    case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :corrupted}
    end
  rescue
    _ -> {:error, :corrupted}
  end

  def unwrap(_wrapped, _kek), do: {:error, :version_mismatch}
end
