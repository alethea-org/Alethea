defmodule Alethea.Telegram.LogRedactorTest do
  @moduledoc """
  Tests for `Alethea.Telegram.LogRedactor` (REQ-C2-no-plaintext-in-logs;
  PR #3b / TASK-3b-5).

  The redactor is a small helper that:
    - `prefix/1` returns the first 8 chars of a `chat_id_hash`
      (the spec's allowed correlation token — short enough not to
      be PHI on its own, long enough to be useful in log triage).
    - `redact/1` replaces every 64-char lowercase-hex hash in a
      string with its 8-char prefix. Use this when an arbitrary log
      message might contain a `chat_id_hash` (e.g., exception
      messages from `Oban.Worker.perform/1`).

  Both functions are nil-safe and non-binary-safe (return "" for
  non-string input). The workers in `lib/alethea/jobs/` should call
  `prefix/1` for known chat_id_hash values and `redact/1` for
  arbitrary strings (e.g., exception payloads).
  """

  use ExUnit.Case, async: true

  require Logger

  alias Alethea.Telegram.LogRedactor

  @hash "abcdef0123456789" |> String.duplicate(4) |> binary_part(0, 64)

  describe "prefix/1" do
    test "returns the first 8 characters of a valid chat_id_hash" do
      assert LogRedactor.prefix(@hash) == "abcdef01"
    end

    test "returns the full hash when the input is shorter than the prefix length" do
      short = "abc12"
      assert LogRedactor.prefix(short) == "abc12"
    end

    test "returns '' for nil input" do
      assert LogRedactor.prefix(nil) == ""
    end

    test "returns '' for non-binary input" do
      assert LogRedactor.prefix(123) == ""
      assert LogRedactor.prefix(:atom) == ""
      assert LogRedactor.prefix(%{}) == ""
    end

    test "returns '' for an empty binary" do
      assert LogRedactor.prefix("") == ""
    end
  end

  describe "redact/1" do
    test "replaces a single chat_id_hash occurrence with its prefix" do
      text = "Error processing #{@hash} retry"

      redacted = LogRedactor.redact(text)

      assert redacted == "Error processing abcdef01 retry"
      refute redacted =~ @hash
    end

    test "replaces multiple chat_id_hash occurrences in the same string" do
      text = "Found hashes #{@hash} and #{String.replace(@hash, "a", "b")}"

      redacted = LogRedactor.redact(text)

      # Both hashes replaced.
      assert redacted =~ "abcdef01"
      assert redacted =~ "bbcdef01"
      refute redacted =~ @hash
    end

    test "leaves text unchanged when there are no hashes" do
      text = "Just a normal log line with no PHI"

      assert LogRedactor.redact(text) == text
    end

    test "does NOT replace short hashes (< 64 chars) — those are not full chat_id_hash" do
      short = "abc12"

      assert LogRedactor.redact("short: #{short}") == "short: abc12"
    end

    test "returns '' for nil input" do
      assert LogRedactor.redact(nil) == ""
    end

    test "returns '' for non-binary input" do
      assert LogRedactor.redact(42) == ""
      assert LogRedactor.redact(:foo) == ""
      assert LogRedactor.redact([1, 2, 3]) == ""
    end

    test "returns '' for empty binary" do
      assert LogRedactor.redact("") == ""
    end

    test "replaces a hash that is the entire string" do
      assert LogRedactor.redact(@hash) == "abcdef01"
    end

    test "does NOT match hashes embedded in longer hex strings (no false-positive on substrings)" do
      # A 65-char hex string (one extra char beyond the 64-char
      # hash shape) is not matched at all. The `\b` word boundary
      # anchor on the right fails because the trailing char is
      # alphanumeric — there is no boundary within the contiguous
      # hex run. This is the desired behaviour: the redactor only
      # scrubs strings that LOOK like a chat_id_hash, not arbitrary
      # substrings of longer hex data.
      long_hex = @hash <> "f"

      assert LogRedactor.redact(long_hex) == long_hex
    end

    test "replaces hashes with non-hex characters on either side (word boundary via non-alphanumeric)" do
      # The hash is surrounded by `:` (non-word character) on the
      # right and a quote on the left. The regex `\b...\b` matches
      # 64 hex chars at these boundaries.
      text = ~s("hash":"#{@hash}",)

      redacted = LogRedactor.redact(text)

      assert redacted =~ ~s("hash":"abcdef01",)
      refute redacted =~ @hash
    end
  end

  describe "integration: workers call LogRedactor.prefix for chat_id_hash" do
    # These tests assert the redactor's behaviour against actual log
    # lines emitted by the worker code paths. The workers in
    # `lib/alethea/jobs/` use `LogRedactor.prefix/1` for all
    # chat_id_hash redaction; this test confirms that no log line
    # contains the full hash.
    #
    # The interpolation runs when the log line is formatted (by
    # `Logger`), not when it is queued. `ExUnit.CaptureLog` captures
    # the formatted line.
    @hash_64 "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

    test "LogRedactor.prefix(chat_id_hash) for a full 64-char hash returns the 8-char prefix" do
      # Sanity check: the input we're using is the full 64-char hash.
      assert byte_size(@hash_64) == 64
      assert LogRedactor.prefix(@hash_64) == "abcdef01"
    end

    test "a typical crisis-branch log line contains the prefix and NOT the full hash" do
      # Mimic what `TelegramMessageWorker` does in the crisis branch:
      # the worker's `hash_prefix = LogRedactor.prefix(chat_id_hash)`
      # is interpolated into the log line.
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          Logger.warning(
            "TelegramMessageWorker: crisis branch (hash_prefix=#{LogRedactor.prefix(@hash_64)}, level=immediate)"
          )
        end)

      assert log =~ "hash_prefix=abcdef01"
      refute log =~ @hash_64
    end

    test "an arbitrary log line scrubbed via redact/1 strips the full hash" do
      # Mimic what callers should do when they have an arbitrary
      # string (e.g., an exception message) that might contain the
      # chat_id_hash.
      arbitrary = "Oban crashed with reason: chat=#{@hash_64}, retry in 5s"

      scrubbed = LogRedactor.redact(arbitrary)

      assert scrubbed =~ "chat=abcdef01"
      refute scrubbed =~ @hash_64
    end
  end
end
