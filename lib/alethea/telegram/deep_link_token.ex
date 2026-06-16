defmodule Alethea.Telegram.DeepLinkToken do
  @moduledoc """
  Pure mint/format helper for the deep-link onboarding token (C-4, pure half).

  Per `REQ-C4-mint-deep-link-token`, the deep-link token is **32 bytes of
  CSPRNG entropy** encoded as URL-safe base64 (no padding). This module
  is the **pure half**: it generates a fresh token and validates the
  canonical format. The persistence half (TTL bookkeeping, used_at,
  attempt_count) lives in `Alethea.Foundation.Accounts.PatientAuthCode`
  in PR #4 — the schema row carries the timestamp, the IP audit, and
  the single-use flag.

  ## Why a pure module (and not a GenServer or schema)

  The token's value is independent of any database state: it is
  256 bits of `crypto.strong_rand_bytes/1` output. There is no
  natural reason for a process or a row to hold the token. Keeping the
  primitive pure means:

  - `mint/0` is testable without `Mix.env() == :test` config or a DB.
  - `valid_format?/1` can be called from any context, including the
    auth controller's input-validation plug, without an `:ets` lookup.
  - The CSPRNG property is a structural assertion: the module has
    no `child_spec/1`, no Repo dependency, no GenServer behaviour.

  ## TTL, single-use, rate-limit

  These concerns live in the `PatientAuthCode` row, not in the token
  itself. The token is a value; the row is the audit trail. The
  pure-half contract here is deliberately narrow: produce a fresh
  canonical token, validate the canonical format, expose nothing
  else.

  See `openspec/sdd/telegram-paciente-foundation/specs/C-4-deep-link-onboarding/spec.md`
  for the full requirement set.
  """

  # 32 raw bytes — the canonical deep-link token entropy. Maps to a
  # 43-character URL-safe base64 string with no padding.
  @raw_byte_size 32

  # URL-safe base64 has no padding by definition; we encode with
  # `padding: false`. For 32 input bytes the result is exactly 43
  # chars: 10 full groups of 3 bytes (40 chars) + 2 remaining bytes
  # encoded as 3 chars (the partial last group uses 12 bits of the
  # last 16 input bits, dropping the low 4 bits). This is a fixed
  # shape, not a range.
  @token_byte_length 43

  # The canonical URL-safe base64 alphabet per RFC 4648 §5. Includes
  # `A-Z`, `a-z`, `0-9`, `-`, and `_`. Notably absent: `+`, `/`, `=`.
  @token_alphabet ~r/^[A-Za-z0-9_-]+$/

  @doc """
  Returns a fresh deep-link token: 32 bytes of CSPRNG entropy encoded
  as URL-safe base64 with no padding (43 chars, alphabet
  `[A-Za-z0-9_-]`).

  The caller is responsible for persisting the token with a TTL, an
  audit row, and the patient binding. The token itself is just a value.

  ## Examples

      iex> token = Alethea.Telegram.DeepLinkToken.mint()
      iex> byte_size(token) == 43
      true
  """
  @spec mint() :: String.t()
  def mint do
    @raw_byte_size
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns `true` if `token` matches the canonical deep-link format
  (43 chars, URL-safe base64 alphabet, no padding). Returns `false`
  for any non-binary input or any malformed string.

  This is the **format check** — not a state check. It does not
  consult the DB, does not check TTL, does not check `used_at`. Those
  concerns live in `Alethea.Foundation.Accounts.verify_patient_auth_code/3`
  in PR #4.

  ## Examples

      iex> Alethea.Telegram.DeepLinkToken.valid_format?("AAAA" <> String.duplicate("A", 39))
      true

      iex> Alethea.Telegram.DeepLinkToken.valid_format?("")
      false

      iex> Alethea.Telegram.DeepLinkToken.valid_format?(nil)
      false
  """
  @spec valid_format?(term()) :: boolean()
  def valid_format?(token) when is_binary(token) do
    byte_size(token) == @token_byte_length and
      Regex.match?(@token_alphabet, token)
  end

  def valid_format?(_), do: false

  @doc """
  The canonical raw byte size (32 bytes → 256 bits of entropy).
  Exposed for tests and downstream callers that need to assert the
  entropy budget.
  """
  @spec raw_byte_size() :: pos_integer()
  def raw_byte_size, do: @raw_byte_size
end
