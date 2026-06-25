defmodule Alethea.Telegram.LogRedactor do
  @moduledoc """
  PHI redaction for Telegram log lines (REQ-C2-no-plaintext-in-logs;
  PR #3b / TASK-3b-5).

  ## Why this module exists

  The Telegram worker emits `Logger.warning` / `Logger.error` lines at
  several points in the inbound-to-outbound pipeline (e.g., crisis
  branch detection, queue-full escalation, dead-letter exhaustion).
  The lines must NOT contain the full `chat_id_hash` (it correlates
  a patient to a specific Telegram chat — a PHI surface) or the raw
  `chat_id` (the same PHI surface in plaintext). The spec
  (`specs/C-2-hmac-chat-id-lookup/spec.md`) allows the first **8
  characters** of the hash as a correlation token — short enough not
  to be PHI on its own (2^32 correlation space) but long enough to
  be useful when triangulating across multiple log lines for one
  inbound update.

  This module centralises the "first 8 chars" rule. Previously each
  worker computed it inline as `String.slice(chat_id_hash, 0, 8)`
  (see `TelegramMessageWorker.process_bound_message/6` and
  `TelegramOutboundWorker.dead_letter_and_broadcast/6`). Centralising
  here means:

    - The prefix length lives in ONE place. Changing it from 8 to 6
      or 10 is a single-edit change.
    - `redact/1` provides a best-effort scrub for arbitrary strings
      (e.g., exception messages from `Oban.Worker.perform/1`) that
      might contain a `chat_id_hash` we did not explicitly redact.

  ## What this module is NOT

  This is NOT a general-purpose PHI redaction layer. It is scoped to
  the Telegram channel's `chat_id_hash` shape (64-char lowercase
  hex, per `Alethea.Telegram.ChatIdHash`). It does NOT redact:

    - Legacy `whatsapp_number_hash` (different shape, different
      risk profile; the WhatsApp pipeline has its own logging).
    - Patient names, aliases, or other PII.
    - The `body` (patient's own words). The `TelegramMessageWorker`
      already avoids logging `body`.

  ## `prefix/1` — explicit hash → 8-char prefix

  Use this when the caller already has a `chat_id_hash` value (the
  common case):

      Logger.warning(
        "TelegramMessageWorker: crisis branch (hash_prefix=\#{LogRedactor.prefix(chat_id_hash)})"
      )

  The function is nil-safe and non-binary-safe (returns `""`).

  ## `redact/1` — arbitrary string → scrubbed

  Use this when the caller has an arbitrary string that might contain
  a `chat_id_hash` (e.g., a `Logger.error` payload, an exception
  message):

      Logger.error("Oban failed: " <> LogRedactor.redact(Exception.message(e)))

  The regex matches any 64-char contiguous lowercase-hex string
  (the chat_id_hash shape). It does NOT validate chat_id_hash
  semantics — it only scrubs strings that LOOK like one. A future
  change to the chat_id_hash format (e.g., base64url-encoded) would
  require updating the regex.

  ## Length rationale (8 chars)

  8 hex chars = 32 bits = ~4 billion distinct correlation tokens.
  Collisions become statistically meaningful above ~65k active
  hashes (birthday paradox), but the Telegram channel's bot has far
  fewer than that active at any time. The 8-char prefix is the
  shortest length that keeps the collision rate negligible in
  production while still leaking well below the 2^64 bits of a full
  hash.
  """

  @prefix_length 8

  # The chat_id_hash shape: 64 contiguous hex characters, case-insensitive
  # (per `Alethea.Telegram.ChatIdHash.hash/2`, which currently produces
  # lowercase hex via `Base.encode16(case: :lower)`, but a future migration
  # to uppercase or a different case encoding would otherwise silently
  # bypass the redactor — `prefix/1` and `redact/1` would reduce to no-ops
  # on a PHI surface). `\b` enforces word boundaries so the regex doesn't
  # accidentally match a substring of a longer hex string (e.g., a 128-char
  # hex digest).
  @hash_regex ~r/\b[0-9a-fA-F]{64}\b/

  @doc """
  Returns the first 8 characters of `chat_id_hash` as a
  non-PHI correlation token.

  Safe to call with any input — nil, non-binary, empty binary all
  return `""`. Use this in log lines where the caller already has
  the `chat_id_hash` value (the common case in the inbound worker).
  """
  @spec prefix(any()) :: String.t()
  def prefix(chat_id_hash) when is_binary(chat_id_hash) do
    String.slice(chat_id_hash, 0, @prefix_length)
  end

  def prefix(_), do: ""

  @doc """
  Replaces every `chat_id_hash`-shaped substring (64-char lowercase
  hex) in `text` with its 8-char prefix.

  Use this for arbitrary log payloads (exception messages, third-party
  error wrappers) that might contain a `chat_id_hash` we did not
  explicitly redact. Safe to call with any input — nil, non-binary,
  empty binary all return `""`.

  ## Caveats

    - Best-effort scrub: the regex matches any 64-char lowercase-hex
      string, not a validated `chat_id_hash`. False positives are
      possible (a 64-char hex substring of a longer hex string is
      matched). False negatives are unlikely (the Telegram channel
      uses the canonical 64-char hex format exclusively).
    - NOT a general PHI redaction layer. See the moduledoc for
      scope.
  """
  @spec redact(any()) :: String.t()
  def redact(text) when is_binary(text) do
    Regex.replace(@hash_regex, text, fn hash -> prefix(hash) end)
  end

  def redact(_), do: ""
end
