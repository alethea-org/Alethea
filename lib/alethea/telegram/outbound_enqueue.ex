defmodule Alethea.Telegram.OutboundEnqueue do
  @moduledoc """
  Thin wrapper over `Oban.insert/1` for the Telegram outbound worker
  jobs (C-7; PR #3b / TASK-3b-3).

  Exists for two reasons:

    1. **Centralisation** — the Oban.insert call site for the
       outbound worker lives in exactly one place. Future changes
       (telemetry, instrumentation, retry semantics) have one point of
       contact instead of two (`enqueue_outbound/6` and the inline
       escalation path).

    2. **Testability** — the wrapper exposes a behaviour so tests can
       Mox it (`Mox.defmock(Mock, for: Alethea.Telegram.OutboundEnqueue)`)
       and stub the insert with a known failure (e.g., `:queue_full`)
       without touching the rest of the Oban system (the emotion
       analysis worker, the inbound worker's other inserts, etc.).

  ## Behaviour contract

  `insert/1` is a 1-arity that takes an `%Ecto.Changeset{}` (typically
  produced by `TelegramOutboundWorker.new/2`) and returns either
  `{:ok, %Oban.Job{}}` or `{:error, term()}` — the standard Oban
  return shape.

  In production, the default implementation delegates to
  `Oban.insert/1` directly. In tests, the `Application` env
  `:alethea, :telegram_outbound_enqueue` can be overridden with a
  Mox mock to drive queue-full scenarios (REQ-C7-crisis-queue-full-escalation
  tests).

  ## Why an env-based indirection (not a compile-time `Application.get_env`)

  The worker reads `:alethea, :telegram_outbound_enqueue` at call-time
  (`perform_now/1` and the enqueue step inside the inbound worker)
  rather than at module-compile time. This lets tests swap the
  adapter mid-test without recompiling the worker module — a standard
  pattern for test-double injection in Elixir.
  """

  @callback insert(Ecto.Changeset.t()) :: {:ok, Oban.Job.t()} | {:error, term()}

  def insert(changeset), do: Oban.insert(changeset)
end
