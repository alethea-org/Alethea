defmodule Alethea.Jobs.TelegramMessageWorkerTest do
  @moduledoc """
  Tests for `Alethea.Jobs.TelegramMessageWorker` (C-3 inbound worker
  stub; PR #3a expands the body).

  The full body (chat_id HMAC, patient lookup, emotion enqueue,
  LLM call, outbound enqueue) lands in PR #3a — see
  `openspec/sdd/telegram-paciente-foundation/tasks.md` §"PR #3a"
  (TASK-3a-1) and `lib/alethea/jobs/telegram_message_worker.ex`
  moduledoc.

  This test file covers the **stub contract** that PR #3a depends on:

    - `use Oban.Worker, queue: :telegram_inbound, max_attempts: 5`
    - The `unique:` config is `24h on telegram_update_id` (R-3 —
      Telegram's monotonic counter is the idempotency key).
    - `perform/1` returns `:ok` so the Oban state machine treats the
      job as successful and does not retry.

  PR #3a will replace `perform/1` with the real clinical round-trip
  body. The contract tests below remain valid (the queue, unique, and
  max_attempts settings are the public-facing stub surface).
  """

  use ExUnit.Case, async: true

  alias Alethea.Jobs.TelegramMessageWorker

  describe "Oban.Worker contract" do
    test "uses Oban.Worker with the telegram_inbound queue and 24h unique on telegram_update_id" do
      opts = TelegramMessageWorker.__opts__()
      assert opts[:queue] == :telegram_inbound
      assert opts[:max_attempts] == 5
      assert opts[:unique] == [period: 86_400, keys: [:telegram_update_id]]
    end

    test ".new/1 builds an Oban Job changeset with the args" do
      args = %{telegram_update_id: 123_456, message: %{"text" => "hi"}}
      changeset = TelegramMessageWorker.new(args)

      assert %Ecto.Changeset{} = changeset
      assert changeset.changes[:args] == args
      assert changeset.changes[:worker] == "Alethea.Jobs.TelegramMessageWorker"
    end
  end

  describe "perform/1 — stub" do
    test "returns :ok so Oban marks the job as successful (no retry)" do
      job = %Oban.Job{args: %{telegram_update_id: 1, message: %{}}}

      assert TelegramMessageWorker.perform(job) == :ok
    end

    test "perform/1 accepts the %Oban.Job{} arg destructured shape used by Oban 2.x" do
      # The stub uses `%Oban.Job{args: args}` as the arg pattern (Oban
      # 2.x calls `perform/1` with the job struct, not just the args
      # map). PR #3a will widen this with the full body but the
      # pattern is part of the stub contract.
      job = %Oban.Job{args: %{telegram_update_id: 1, message: %{"text" => "hello"}}}
      assert :ok = TelegramMessageWorker.perform(job)
    end
  end
end
