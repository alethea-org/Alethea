defmodule Alethea.Jobs.TelegramOnboardingWorkerTest do
  @moduledoc """
  Tests for `Alethea.Jobs.TelegramOnboardingWorker` (C-4 onboarding
  worker stub; PR #3a expands the body and PR #4 wires the
  `PatientAuthCode` schema).

  The full body (token verification, `Accounts.bind_patient_to_chat/2`,
  welcome emission) lands in PR #3a / PR #4 — see
  `openspec/sdd/telegram-paciente-foundation/tasks.md` §"PR #3a"
  and §"PR #4".

  This test file covers the **stub contract** that PR #3a / PR #4
  depend on:

    - `use Oban.Worker, queue: :telegram_inbound, max_attempts: 5`
    - The `unique:` config is **none** — `/start` is safe to re-enqueue
      because the deep-link token is single-use at the DB layer (PR
      #4), so a duplicate enqueue cannot bind a chat twice. A unique
      constraint here would be redundant and would mask genuine
      retries (e.g. a worker that crashed mid-bind).
    - `perform/1` returns `:ok` so the Oban state machine treats the
      job as successful and does not retry.

  The args shape is `%{telegram_update_id: integer, token: binary() | nil}`
  (a `nil` token means the patient opened the chat cold with no
  professional pre-minted link).
  """

  use ExUnit.Case, async: true

  alias Alethea.Jobs.TelegramOnboardingWorker

  describe "Oban.Worker contract" do
    test "uses Oban.Worker with the telegram_inbound queue, no unique" do
      opts = TelegramOnboardingWorker.__opts__()
      assert opts[:queue] == :telegram_inbound
      assert opts[:max_attempts] == 5
      # No unique constraint — see moduledoc for the rationale.
      # When the `unique` key is absent, Oban.Worker stores `nil`
      # (not `[]`); both are semantically "no uniqueness".
      assert opts[:unique] in [nil, []]
    end

    test ".new/1 builds an Oban Job changeset with the args" do
      args = %{telegram_update_id: 123_456, token: "abc.def.ghi"}
      changeset = TelegramOnboardingWorker.new(args)

      assert %Ecto.Changeset{} = changeset
      assert changeset.changes[:args] == args
      assert changeset.changes[:worker] == "Alethea.Jobs.TelegramOnboardingWorker"
    end
  end

  describe "perform/1 — stub" do
    test "returns :ok so Oban marks the job as successful (no retry)" do
      job = %Oban.Job{args: %{telegram_update_id: 1, token: nil}}
      assert TelegramOnboardingWorker.perform(job) == :ok
    end

    test "perform/1 accepts a token in args (deep-link path)" do
      job = %Oban.Job{args: %{telegram_update_id: 1, token: "abc.def.ghi"}}
      assert :ok = TelegramOnboardingWorker.perform(job)
    end

    test "perform/1 accepts nil token (cold-open path)" do
      job = %Oban.Job{args: %{telegram_update_id: 1, token: nil}}
      assert :ok = TelegramOnboardingWorker.perform(job)
    end
  end
end
