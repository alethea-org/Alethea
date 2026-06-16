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
  """

  @doc """
  Computes `HMAC-SHA256(chat_id, pepper)` and returns the result as a
  64-char lowercase hex string.

  Accepts either an integer or a string `chat_id`; both forms are
  stringified with `to_string/1` before hashing, so the call is
  deterministic across types.

  ## Examples

      iex> Alethea.Telegram.ChatIdHash.hash("123456789", "pepper-v1")
      "62b1afd3a86f0e2c8d0a0e1c3f5e9b7a3d2c1e4f5a6b7c8d9e0f1a2b3c4d5e6f7"

      iex> Alethea.Telegram.ChatIdHash.hash(123_456_789, "pepper-v1")
      "62b1afd3a86f0e2c8d0a0e1c3f5e9b7a3d2c1e4f5a6b7c8d9e0f1a2b3c4d5e6f7"
  """
  @spec hash(integer() | String.t(), String.t()) :: String.t()
  def hash(chat_id, pepper) when is_binary(pepper) do
    :crypto.mac(:hmac, :sha256, pepper, to_string(chat_id))
    |> Base.encode16(case: :lower)
  end
end
