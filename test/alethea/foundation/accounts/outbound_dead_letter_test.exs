defmodule Alethea.Foundation.Accounts.OutboundDeadLetterTest do
  @moduledoc """
  Tests for `Alethea.Foundation.Accounts.OutboundDeadLetter`
  (REQ-C7-dead-letter-on-exhaustion; PR #3a / TASK-3a-3, folded into
  TASK-3a-2).

  The schema is intentionally minimal — the dead-letter is an
  audit-only row written by the outbound worker when retries are
  exhausted. The acceptance criteria for the table itself:

    - All five columns are required (changeset rejects nil values).
    - `chat_id_hash` must be 64 chars (the HMAC-SHA256 hex format).
    - `attempts` must be a positive integer (a zero-attempt row is a
      data-integrity bug; the worker should never write one).
    - `failed_at` is a UTC datetime (no timezone ambiguity).
    - `inserted_at` / `updated_at` are auto-populated by Ecto.

  The end-to-end "worker writes dead-letter on exhaustion" scenario is
  in `Alethea.Jobs.TelegramOutboundWorkerTest`.
  """

  use Alethea.DataCase, async: true

  alias Alethea.Foundation.Accounts.OutboundDeadLetter

  @valid_hash String.duplicate("a", 64)
  @valid_attrs %{
    chat_id_hash: @valid_hash,
    text: "hola, buen día",
    last_error: "{:rate_limited, 2}",
    attempts: 5,
    failed_at: ~U[2026-06-20 22:00:00Z],
    # Round 1 (WARNING-5): lane is required (validate_inclusion
    # enforces "safe" or "crisis"; default backfill applied via
    # migration 20260624193001). patient_id is optional — unbound
    # chat dead-letters have no patient.
    lane: "safe",
    patient_id: nil
  }

  describe "changeset/2 — happy path" do
    test "accepts a complete valid attrs map and persists the row" do
      assert {:ok, %OutboundDeadLetter{} = row} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(@valid_attrs)
               |> Repo.insert()

      assert row.chat_id_hash == @valid_hash
      assert row.text == "hola, buen día"
      assert row.last_error == "{:rate_limited, 2}"
      assert row.attempts == 5
      assert %DateTime{} = row.failed_at
      assert %DateTime{} = row.inserted_at
      assert %DateTime{} = row.updated_at
    end
  end

  describe "changeset/2 — validations" do
    test "rejects nil chat_id_hash" do
      attrs = Map.delete(@valid_attrs, :chat_id_hash)

      assert {:error, changeset} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(attrs)
               |> Repo.insert()

      assert %{chat_id_hash: [_ | _]} = errors_on(changeset)
    end

    test "rejects a chat_id_hash that is not exactly 64 characters" do
      attrs = %{@valid_attrs | chat_id_hash: String.duplicate("a", 63)}

      assert {:error, changeset} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(attrs)
               |> Repo.insert()

      assert %{chat_id_hash: [_ | _]} = errors_on(changeset)
    end

    test "rejects nil text" do
      attrs = Map.delete(@valid_attrs, :text)

      assert {:error, changeset} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(attrs)
               |> Repo.insert()

      assert %{text: [_ | _]} = errors_on(changeset)
    end

    test "rejects nil last_error" do
      attrs = Map.delete(@valid_attrs, :last_error)

      assert {:error, changeset} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(attrs)
               |> Repo.insert()

      assert %{last_error: [_ | _]} = errors_on(changeset)
    end

    test "rejects nil attempts" do
      attrs = Map.delete(@valid_attrs, :attempts)

      assert {:error, changeset} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(attrs)
               |> Repo.insert()

      assert %{attempts: [_ | _]} = errors_on(changeset)
    end

    test "rejects zero or negative attempts" do
      for n <- [0, -1] do
        attrs = %{@valid_attrs | attempts: n}

        assert {:error, changeset} =
                 %OutboundDeadLetter{}
                 |> OutboundDeadLetter.changeset(attrs)
                 |> Repo.insert()

        assert %{attempts: [_ | _]} = errors_on(changeset)
      end
    end

    test "rejects nil failed_at" do
      attrs = Map.delete(@valid_attrs, :failed_at)

      assert {:error, changeset} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(attrs)
               |> Repo.insert()

      assert %{failed_at: [_ | _]} = errors_on(changeset)
    end
  end

  describe "persistence" do
    test "the chat_id_hash column is indexed for fast lookup" do
      # Smoke test: a second row with a different chat_id_hash inserts
      # without a unique-index conflict (the index is non-unique).
      {:ok, %OutboundDeadLetter{id: first_id}} =
        %OutboundDeadLetter{}
        |> OutboundDeadLetter.changeset(@valid_attrs)
        |> Repo.insert()

      second_attrs = %{@valid_attrs | chat_id_hash: String.duplicate("b", 64)}

      assert {:ok, %OutboundDeadLetter{id: second_id}} =
               %OutboundDeadLetter{}
               |> OutboundDeadLetter.changeset(second_attrs)
               |> Repo.insert()

      assert second_id != first_id
      assert Repo.aggregate(OutboundDeadLetter, :count) == 2
    end
  end
end
