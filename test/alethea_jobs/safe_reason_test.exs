defmodule AletheaJobs.SafeReasonTest do
  @moduledoc """
  Unit tests for `AletheaJobs.SafeReason.for_log/1`.

  The helper is the per-call PHI-safe error renderer used by:
    - `AletheaJobs.SessionTimeoutWorker:215-229` (R2 #86 PR-1 fix
      — embedding `Ecto.Changeset.changes` from a failing
      `Clinical.save_summary/1` call into the Logger.error line
      would leak `summary_text` + `patient_id`)
    - `Alethea.Jobs.TelegramMessageWorker` (3 call sites — inbound
      save, AI reply/diagnosis save, crisis outbound save; the
      `safe_reason/1` was extracted to the shared module in #86 R2)

  These tests assert the contract the worker sites rely on:
    1. A Changeset with validation errors yields ONLY the failed
       field keys — the `changes` map (which embeds `summary_text`,
       `body`, etc.) NEVER appears in the output.
    2. Multiple errors on the same field are deduplicated (`Enum.uniq/1`).
    3. Non-changeset reasons pass through `inspect/1` unchanged.
    4. The fallback for non-changeset reasons is safe for
       non-changeset shapes (`:timeout`, error tuples).
  """

  use ExUnit.Case, async: true

  doctest AletheaJobs.SafeReason

  alias AletheaJobs.SafeReason

  # The fake PHI value used across the changeset tests. Asserting
  # that this string NEVER appears in `for_log/1` output is the
  # contract: a Changeset whose `changes` carries sensitive content
  # must not be embedded in a log line via the helper.
  @phi_sentinel "PHI-CONTENT-DO-NOT-LOG-12345"

  describe "for_log/1 — Changeset input" do
    test "surfaces only the failed-validation field keys" do
      cs = %Ecto.Changeset{
        errors: [summary_text: {"can't be blank", [validation: :required]}],
        changes: %{summary_text: @phi_sentinel}
      }

      assert SafeReason.for_log(cs) == "[:summary_text]"
    end

    test "NEVER embeds the `changes` map (the PHI surface) in the output" do
      # This is the core contract: the `changes` map is the PHI surface
      # (e.g. `summary_text`, `body`, `ai_response`). If a future
      # refactor accidentally re-introduces `inspect/1` on the full
      # Changeset, the sentinel below would appear in the output and
      # this test would fail.
      cs = %Ecto.Changeset{
        errors: [summary_text: {"can't be blank", [validation: :required]}],
        changes: %{
          summary_text: @phi_sentinel,
          patient_id: "11111111-1111-1111-1111-111111111111"
        }
      }

      output = SafeReason.for_log(cs)

      refute output =~ @phi_sentinel,
             "for_log/1 leaked the `changes` map — `summary_text` PHI appeared in: #{inspect(output)}"

      refute output =~ "11111111-1111-1111-1111-111111111111",
             "for_log/1 leaked the `changes` map — `patient_id` UUID appeared in: #{inspect(output)}"
    end

    test "NEVER embeds the `data` struct map either (defense in depth)" do
      # The Changeset's `data` map is ALSO a sensitive surface — for a
      # `%Summary{}` it carries the previously-persisted `summary_text`
      # (or the fresh struct's empty fields). Confirm `for_log/1` does
      # not pull it in either.
      cs = %Ecto.Changeset{
        errors: [summary_text: {"can't be blank", [validation: :required]}],
        data: %Alethea.Clinical.Summary{summary_text: @phi_sentinel}
      }

      output = SafeReason.for_log(cs)

      refute output =~ @phi_sentinel
    end

    test "lists multiple field keys in the order Ecto surfaces them" do
      cs = %Ecto.Changeset{
        errors: [
          body: {"can't be blank", []},
          summary_text: {"too short", []}
        ]
      }

      assert SafeReason.for_log(cs) == "[:body, :summary_text]"
    end

    test "deduplicates a field key with multiple errors (Enum.uniq/1)" do
      # The same field can carry multiple errors (e.g. `:required` AND
      # `:too_short`). `for_log/1` keys-only, deduplicated.
      cs = %Ecto.Changeset{
        errors: [
          {:summary_text, {"can't be blank", [validation: :required]}},
          {:summary_text, {"too short", [validation: :too_short]}}
        ]
      }

      assert SafeReason.for_log(cs) == "[:summary_text]"
    end

    test "a Changeset with no errors returns an empty list" do
      # `errors: []` — this is the rare case where a Changeset is
      # `valid?` but is still a struct (e.g., programmer error passing
      # the wrong shape). The output is `"[]"` (no PHI; no keys).
      cs = %Ecto.Changeset{errors: [], changes: %{summary_text: @phi_sentinel}}

      assert SafeReason.for_log(cs) == "[]"
      refute SafeReason.for_log(cs) =~ @phi_sentinel
    end
  end

  describe "for_log/1 — non-Changeset fallback" do
    test "atoms pass through inspect/1" do
      assert SafeReason.for_log(:timeout) == ":timeout"
      assert SafeReason.for_log(:queue_full) == ":queue_full"
      assert SafeReason.for_log(:ok) == ":ok"
    end

    test "nil passes through inspect/1 as the literal 'nil'" do
      # `nil` is not an atom in the printed sense that Elixir uses
      # `:nil` — `inspect(nil)` is the string `"nil"`. This documents
      # the behaviour explicitly so a future refactor that special-cases
      # nil (e.g. returning `""`) gets caught.
      assert SafeReason.for_log(nil) == "nil"
    end

    test "error tuples pass through inspect/1" do
      assert SafeReason.for_log({:error, :queue_full}) ==
               "{:error, :queue_full}"

      assert SafeReason.for_log({:error, "string reason"}) ==
               ~s({:error, "string reason"})
    end

    test "plain strings pass through inspect/1" do
      # A string reason (rare, but possible from a third-party
      # wrapper). `inspect/1` adds quotes around it.
      assert SafeReason.for_log("deadline exceeded") ==
               ~s("deadline exceeded")
    end

    test "binary PHI-in-error (a string reason carrying PHI) is rendered as-is" do
      # NOTE: this is a deliberate LIMITATION of the helper. A
      # non-Changeset reason may itself carry PHI (e.g. a service
      # wrapper returning `{:error, "decryption failed for message
      # #{ciphertext}"}`). The for_log/1 fallback renders it via
      # `inspect/1` because we cannot infer the PHI surface from the
      # type alone. Callers that propagate PHI in non-Changeset reasons
      # should wrap the string with `Alethea.Telegram.LogRedactor.redact/1`
      # (64-char hex chat_id_hash) or apply a future PHI scrubber.
      # Asserting the current behaviour so any change to it is
      # explicit.
      assert SafeReason.for_log({:error, "raw phi text"}) ==
               ~s({:error, "raw phi text"})
    end

    test "integers and other terms pass through inspect/1" do
      assert SafeReason.for_log(42) == "42"
      assert SafeReason.for_log([1, 2, 3]) == "[1, 2, 3]"
    end
  end
end
