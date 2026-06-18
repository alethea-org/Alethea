defmodule Alethea.Telegram.ChatIdHash do
  @moduledoc """
  Pure HMAC-SHA256 helper for the Telegram `chat_id` lookup key.

  Per `REQ-C2-chat-id-stored-as-hmac`, the system never stores, queries, or
  logs a raw Telegram `chat_id`. The lookup key is
  `HMAC-SHA256(chat_id, pepper)` encoded as lowercase hex (64 chars), and
  the column is `foundation_patients.telegram_chat_id_hash` with a partial
  unique index.

  ## Why a pure module

  This is a single, side-effect-free function. It takes the `chat_id` and
  the per-deployment pepper, and returns a 64-char lowercase hex string.
  No I/O, no ETS, no GenServer. The function is safe to call from any
  context, including the test suite (async-safe).

  ## One-way property

  The module exposes a single function, `hash/2`. There is no `decode`,
  `unhash`, `reverse`, `recover`, or `decrypt`. HMAC-SHA256 is a one-way
  primitive: the chat_id cannot be recovered from the hash without the
  pepper. This is the cryptographic-erasure surface: rotating the pepper
  and re-`NULL`-ing the column renders the old bindings useless, without
  any leakage of the previous chat_ids.

  ## Pepper

  The pepper is read from `Application.get_env(:alethea, :telegram_chat_id_pepper)`
  in callers. This module takes the pepper as an argument to keep it pure
  and trivially testable. The lookup is a one-time string; future
  per-psychologist pepper changes are a separate refactor (see ADR-0008
  stub in the change design).

  ### Pepper length minimum (32 bytes)

  `hash/2` requires the pepper to be **at least 32 bytes**. HMAC-SHA256
  with a 0-byte or short key is cryptographically weak (the security
  bound collapses to the key length). A `byte_size(pepper) < 32` value
  raises `ArgumentError` rather than silently producing a weak hash. In
  production the pepper is a deployment secret and is expected to be
  generated at ≥ 32 random bytes by the secret manager.
  """

  @doc """
  Computes `HMAC-SHA256(chat_id, pepper)` and returns the result as a
  64-char lowercase hex string.

  Accepts either an integer or a string `chat_id`; both forms are
  stringified with `to_string/1` before hashing, so the call is
  deterministic across types.

  ## Examples

      iex> Alethea.Telegram.ChatIdHash.hash("123456789", "pepper-v1-32-bytes-min-len-padding-pad")
      "bef615b48f2c547f4d5bd20f44c2d3814c043f80762361ff25c1a8cf88ad1891"

      iex> Alethea.Telegram.ChatIdHash.hash(123_456_789, "pepper-v1-32-bytes-min-len-padding-pad")
      "bef615b48f2c547f4d5bd20f44c2d3814c043f80762361ff25c1a8cf88ad1891"
  """
  @spec hash(integer() | String.t(), String.t()) :: String.t()
  def hash(chat_id, pepper)
      when (is_integer(chat_id) or is_binary(chat_id)) and is_binary(pepper) and
             byte_size(pepper) >= 32 do
    :crypto.mac(:hmac, :sha256, pepper, to_string(chat_id))
    |> Base.encode16(case: :lower)
  end

  def hash(_chat_id, pepper) when is_binary(pepper) and byte_size(pepper) < 32 do
    raise ArgumentError,
          "Alethea.Telegram.ChatIdHash.hash/2: pepper must be at least 32 bytes " <>
            "(got #{byte_size(pepper)} bytes). " <>
            "HMAC-SHA256 with a 0-byte or short key is cryptographically weak."
  end

  def hash(chat_id, _pepper) do
    raise ArgumentError,
          "Alethea.Telegram.ChatIdHash.hash/2: chat_id must be an integer or a string " <>
            "(got #{inspect(chat_id)})"
  end
end
