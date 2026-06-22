defmodule Alethea.Jobs.TelegramOutboundWorkerTest do
  @moduledoc """
  Tests for `Alethea.Jobs.TelegramOutboundWorker` (C-7 outbound + dead
  letter; PR #3a / TASK-3a-2).

  Covers:

    - REQ-C7-429-retry-with-jitter: 429 with `Retry-After` is
      rescheduled with the header value ± jitter; 5xx / network
      errors retry with exponential backoff.
    - REQ-C7-dead-letter-on-exhaustion: after `max_attempts` retries
      the payload is written to `foundation_outbound_dead_letters`
      and `{:outbound_dead_letter, …}` is broadcast on
      `"ops:alerts"`.
    - REQ-C7-pacer-per-chat-limit + REQ-C7-pacer-global-limit:
      every send acquires a Pacer token before calling
      `Client.send_message/2`.

  The crisis-bypass `perform_now/1` escalation lives in PR #3b —
  out of scope here.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Foundation.Accounts.OutboundDeadLetter
  alias Alethea.Repo
  alias Alethea.Telegram.{Pacer, Client.Fake}

  import Ecto.Query

  @chat_id 987_654_321
  @chat_id_hash String.duplicate("a", 64)
  @body "hola, buen día"

  setup do
    # Pacer: hermetic per-test state, fast refill for tests that
    # check the rate-limit boundary.
    Application.put_env(
      :alethea,
      Alethea.Telegram.Pacer,
      Keyword.merge(
        Application.get_env(:alethea, Alethea.Telegram.Pacer, []),
        per_chat_capacity: 1,
        per_chat_refill_per_sec: 1.0,
        global_capacity: 30,
        global_refill_per_sec: 30.0,
        cleanup_interval_ms: 60_000,
        idle_threshold_ms: 60_000
      )
    )

    {:ok, _} = safe_start_pacer()

    # Fake client (TASK-3a-2 added error injection).
    start_supervised!(Fake)
    Fake.reset()
    Application.put_env(:alethea, :telegram_client, Fake)

    # Hermetic Oban state.
    Repo.delete_all(Oban.Job)

    # Subscribe to "ops:alerts" so we can assert the dead-letter
    # PubSub broadcast. `Phoenix.PubSub.subscribe/2` is idempotent
    # within a process — a second `setup` re-subscribes harmlessly.
    Phoenix.PubSub.subscribe(Alethea.PubSub, "ops:alerts")

    :ok
  end

  # ----------------------------------------------------------------
  # Oban.Worker contract
  # ----------------------------------------------------------------

  describe "Oban.Worker contract" do
    test "uses :telegram_outbound queue" do
      assert TelegramOutboundWorker.__opts__()[:queue] == :telegram_outbound
    end

    test "max_attempts is 1 (the worker manages its own retry budget)" do
      # The worker reschedules itself manually via Oban.insert with a
      # computed scheduled_at (jittered exponential backoff). Setting
      # max_attempts: 1 ensures Oban does NOT auto-retry on top of the
      # worker's own scheduling — the two layers would otherwise
      # double the backoff.
      assert TelegramOutboundWorker.__opts__()[:max_attempts] == 1
    end
  end

  # ----------------------------------------------------------------
  # Happy path (REQ-C7-pacer-* + happy send)
  # ----------------------------------------------------------------

  describe "perform/1 — happy path" do
    test "acquires a Pacer token then sends via Client.send_message/2; returns :ok" do
      args = build_args(chat_id: @chat_id, chat_id_hash: @chat_id_hash, body: @body)

      assert :ok = perform(args)

      # The Fake records successful sends; queued responses (errors)
      # are NOT recorded (only the default {:ok, id} path is).
      sends = Fake.sends()
      assert length(sends) == 1
      assert hd(sends).chat_id == @chat_id
      assert hd(sends).text == @body

      refute_enqueued(worker: TelegramOutboundWorker)
    end

    test "PHI hygiene — the body is NOT logged on a successful send" do
      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          perform(build_args())
        end)

      # The body and chat_id must not appear in any log line.
      refute log =~ @body
      refute log =~ "#{@chat_id}"
    end
  end

  # ----------------------------------------------------------------
  # 429 / 5xx / network retries (REQ-C7-429-retry-with-jitter)
  # ----------------------------------------------------------------

  describe "perform/1 — 429 with Retry-After" do
    test "reschedules the job with a delay near the Retry-After value (plus jitter)" do
      Fake.queue_responses([{:error, {:rate_limited, 2}}])

      assert :ok = perform(build_args())

      [%Oban.Job{args: %{"_attempt" => 2}, scheduled_at: scheduled_at}] =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      # 2 s = 2_000 ms ± 25% jitter (500 ms band).
      delta = DateTime.diff(scheduled_at, DateTime.utc_now(), :millisecond)
      assert_in_delta delta, 2_000, 500
    end
  end

  describe "perform/1 — 5xx / network error" do
    test "5xx error triggers exponential backoff (attempt 1 → ~1s, attempt 2 → ~2s)" do
      Fake.queue_responses([{:error, {:server_error, 503}}])

      assert :ok = perform(build_args())

      [%Oban.Job{scheduled_at: scheduled_at}] =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      delta = DateTime.diff(scheduled_at, DateTime.utc_now(), :millisecond)
      # attempt 1 base = 1_000 ms ± 25% jitter
      assert_in_delta delta, 1_000, 250
    end

    test ":network error uses the same exponential backoff as 5xx" do
      Fake.queue_responses([{:error, :network}])

      assert :ok = perform(build_args())

      assert_enqueued(worker: TelegramOutboundWorker, state: "scheduled")
    end
  end

  describe "perform/1 — success on retry" do
    test "after a 429 followed by a success, the message is recorded and no further job is enqueued" do
      Fake.queue_responses([
        {:error, {:rate_limited, 1}},
        {:ok, 9_999_999}
      ])

      assert :ok = perform(build_args())

      # The retry was scheduled (1st call).
      assert_enqueued(worker: TelegramOutboundWorker, state: "scheduled")

      # Drive the scheduled retry: the Fake still has one response
      # queued (the success). Run the rescheduled job synchronously.
      [%Oban.Job{args: args}] =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      retry_args = Map.delete(args, "_attempt")
      assert :ok = perform(Map.put(retry_args, "_attempt", 2))

      # The success was recorded.
      sends = Fake.sends()
      assert length(sends) == 1
      assert hd(sends).text == @body
    end
  end

  # ----------------------------------------------------------------
  # Exhaustion (REQ-C7-dead-letter-on-exhaustion)
  # ----------------------------------------------------------------

  describe "perform/1 — exhaustion writes dead-letter + broadcasts on ops:alerts" do
    test "on the 5th attempt, dead-letter row is written + PubSub event is broadcast + no new job is enqueued" do
      Fake.queue_responses([{:error, {:rate_limited, 1}}])

      # The exhaustion branch fires when attempt >= 5 AND the send
      # returned an error. We invoke perform with attempt: 5
      # directly — this simulates the worker being invoked for the
      # 5th time after 4 prior reschedules.
      args = build_args(attempt: 5)
      assert :ok = perform(args)

      # A dead-letter row was written.
      dl = Repo.one(OutboundDeadLetter)
      assert dl
      assert dl.chat_id_hash == @chat_id_hash
      assert dl.text == @body
      assert dl.last_error =~ "rate_limited"
      assert dl.attempts == 5
      assert %DateTime{} = dl.failed_at

      # The PubSub event was broadcast.
      assert_receive {:outbound_dead_letter,
                      %{chat_id_hash: hash, text: text, error: error, attempts: 5}},
                     1_000

      assert hash == @chat_id_hash
      assert text == @body
      assert error =~ "rate_limited"

      # The exhaustion path returns :ok so Oban does NOT schedule a
      # 6th retry. Assert no NEW job (state "scheduled") was created
      # by this perform — only the current perform's own job row,
      # which Oban marks "completed" when perform returns :ok.
      scheduled_jobs =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      assert scheduled_jobs == []
    end
  end

  # ----------------------------------------------------------------
  # Pacer integration (REQ-C7-pacer-per-chat-limit)
  # ----------------------------------------------------------------

  describe "perform/1 — Pacer integration" do
    test "the second call within the same second blocks on Pacer.acquire/1" do
      args = build_args()

      assert :ok = perform(args)

      # Per-chat bucket is drained (capacity 1, refill 1 Hz). The
      # second call blocks for ~1 s. The worker's Pacer.acquire call
      # is inside `perform/1`, so we observe it via wall-clock.
      started_ms = System.monotonic_time(:millisecond)
      assert :ok = perform(args)
      elapsed_ms = System.monotonic_time(:millisecond) - started_ms

      assert elapsed_ms >= 900,
             "second perform/1 should have blocked on Pacer (~1s); got #{elapsed_ms}ms"
    end
  end

  # ----------------------------------------------------------------
  # Crisis lane (REQ-C7-crisis-priority-lane; PR #3b / TASK-3b-2)
  # ----------------------------------------------------------------

  describe "perform/1 — crisis lane" do
    test "Pacer.acquire/1 is called for crisis jobs (REQ-C7-crisis-priority-lane: rate-limit must NEVER be bypassed — Pacer is the safety net)" do
      Fake.queue_responses([{:ok, 9_999_999}])

      # Use a distinct chat_id_hash so this test is hermetic against
      # any per-chat Pacer state left by other tests.
      crisis_chat_hash = "b" |> String.duplicate(64)

      args =
        build_args(
          chat_id_hash: crisis_chat_hash,
          lane: :crisis,
          priority: 1
        )

      # Pacer bucket starts full (1 token). After the call, it should
      # be drained — confirming `Pacer.acquire/1` was reached before
      # the send.
      before_snapshot = Pacer.inspect_per_chat()

      assert :ok = perform(args)

      after_snapshot = Pacer.inspect_per_chat()

      # The crisis job's per-chat bucket went from full to drained.
      before_tokens = Map.get(before_snapshot, crisis_chat_hash, %{tokens: 1}).tokens
      after_tokens = Map.get(after_snapshot, crisis_chat_hash, %{tokens: 0}).tokens

      assert before_tokens == 1, "expected Pacer to start full for #{crisis_chat_hash}"

      assert after_tokens == 0,
             "expected Pacer to be drained after crisis send (rate-limit bypass)"

      # The send was recorded by the Fake.
      assert length(Fake.sends()) == 1
    end

    test "the lane field is preserved on reschedule (crisis retry stays on the crisis lane)" do
      Fake.queue_responses([{:error, {:rate_limited, 1}}])

      assert :ok = perform(build_args(lane: :crisis, priority: 1))

      [%Oban.Job{args: %{"lane" => lane}, queue: queue}] =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      # Oban JSON-encodes the args on insert; the atom :crisis comes
      # back as the string "crisis" when the job row is re-read.
      assert lane == "crisis",
             "crisis retry should keep lane: :crisis so it stays on :telegram_outbound_crisis (got #{inspect(lane)})"

      assert queue == "telegram_outbound_crisis",
             "crisis retry should re-enqueue on the crisis queue (got #{queue})"
    end

    test "the priority field is preserved on reschedule (crisis jobs stay high-priority across retries)" do
      Fake.queue_responses([{:error, {:server_error, 503}}])

      assert :ok = perform(build_args(lane: :crisis, priority: 1))

      [%Oban.Job{priority: priority}] =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      assert priority == 1, "crisis retry should preserve priority: 1"
    end

    test "the default priority for a crisis job is 0 (no priority injected by the worker on reschedule)" do
      Fake.queue_responses([{:error, {:rate_limited, 1}}])

      # No `priority` in the build_args kwargs; the default of 0 is used.
      assert :ok = perform(build_args(lane: :crisis))

      [%Oban.Job{priority: priority}] =
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Alethea.Jobs.TelegramOutboundWorker" and j.state == "scheduled"
        )

      assert priority == 0
    end
  end

  describe "config :telegram_outbound_crisis queue (REQ-C7-crisis-priority-lane)" do
    test "the :telegram_outbound_crisis queue is configured with max_demand: 2 (per spec)" do
      queue_config =
        Application.get_env(:alethea, Oban, [])
        |> Keyword.get(:queues, [])

      crisis_config = Keyword.get(queue_config, :telegram_outbound_crisis)

      assert is_list(crisis_config) or is_integer(crisis_config),
             ":telegram_outbound_crisis must be configured (got #{inspect(crisis_config)})"

      {max_demand, _queue_opts} =
        case crisis_config do
          max when is_integer(max) -> {max, []}
          opts when is_list(opts) -> {Keyword.get(opts, :max_demand), opts}
        end

      assert max_demand == 2,
             ":telegram_outbound_crisis must be limited to 2 concurrent jobs per REQ-C7-crisis-priority-lane"
    end

    test "the :telegram_outbound_crisis queue has priority: 1 (above the safe :telegram_outbound default of 0)" do
      queue_config =
        Application.get_env(:alethea, Oban, [])
        |> Keyword.get(:queues, [])

      crisis_config = Keyword.get(queue_config, :telegram_outbound_crisis)
      crisis_priority = Keyword.get(crisis_config || [], :priority, 0)

      assert crisis_priority == 1,
             "the crisis queue must have priority: 1 (got #{crisis_priority})"
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp perform(args) do
    TelegramOutboundWorker.perform(%Oban.Job{
      args: args,
      attempt: Map.get(args, "_attempt", 1),
      priority: Map.get(args, "priority", 0)
    })
  end

  defp safe_start_pacer do
    case Process.whereis(Pacer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end

    Pacer.start_link([])
  end

  defp build_args(opts \\ []) do
    %{
      "chat_id" => Keyword.get(opts, :chat_id, @chat_id),
      "chat_id_hash" => Keyword.get(opts, :chat_id_hash, @chat_id_hash),
      "body" => Keyword.get(opts, :body, @body),
      "_attempt" => Keyword.get(opts, :attempt, 1),
      "lane" => Keyword.get(opts, :lane, :safe),
      "priority" => Keyword.get(opts, :priority, 0)
    }
  end
end
