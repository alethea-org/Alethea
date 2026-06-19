defmodule AletheaWeb.TelegramWebhookControllerTest do
  @moduledoc """
  Tests for `AletheaWeb.TelegramWebhookController` (C-1 inbound entrypoint).

  Covers the four `REQ-C1-webhook-*` scenarios:

      - `update/2` returns 200 immediately, even before the worker runs
        (latency-critical fast-ack; Telegram retries if no 200 within ~10s)
      - `update/2` enqueues an `Alethea.Jobs.TelegramMessageWorker` for
        non-`/start` messages
      - `update/2` enqueues an `Alethea.Jobs.TelegramOnboardingWorker` when
        `message.text` starts with `/start`, with the deep-link token
        extracted as a separate `args` key
      - malformed updates (missing `update_id` / missing `message`) still
        return 200 (ack-and-drop, NOT a 4xx — better to ack and let the
        worker decide than to retry-spam Telegram)

  Plus the Oban 24h uniqueness contract on `telegram_update_id` (R-3) —
  a second enqueue within the period is silently dropped, not retried.

  ## Test wiring

  The controller is dispatched directly via `Phoenix.ConnTest.dispatch/5`
  because TASK-2-5 (router pipeline) is not yet wired. The
  `TelegramSecretToken` plug (TASK-2-2) is in the router pipeline, NOT
  the controller pipeline, so the controller's 401 path is not exercised
  here — the plug's tests are the contract for auth, and the controller
  assumes the plug has already validated.

  The Oban config is `testing: :manual` (see `config/test.exs`); jobs
  are inserted into the DB but never auto-processed, so we can assert
  on the `oban_jobs` table without a real worker draining it.
  """

  use AletheaWeb.ConnCase, async: false
  import Ecto.Query
  import Oban.Testing
  import Phoenix.ConnTest

  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOnboardingWorker}
  alias AletheaWeb.TelegramWebhookController

  @moduletag :telegram

  setup do
    # Hermetic counts: the queue is shared across all `telegram_inbound`
    # jobs in the test process's Oban sandbox, so we start each test
    # with a clean `oban_jobs` table.
    Alethea.Repo.delete_all(Oban.Job)
    :ok
  end

  describe "update/2 — non-/start happy path" do
    test "returns 200 and enqueues a TelegramMessageWorker", %{conn: conn} do
      body = build_update(%{"text" => "hello"})

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      assert_enqueued(Alethea.Repo,
        worker: TelegramMessageWorker,
        args: %{telegram_update_id: 123_456, message: body["message"]}
      )
    end

    test "the enqueued job carries the original message in args (no transformation at the entrypoint)",
         %{conn: conn} do
      message = %{
        "message_id" => 42,
        "date" => 1_700_000_000,
        "chat" => %{"id" => 987_654, "type" => "private"},
        "text" => "hola, hoy fue un día difícil"
      }

      body = %{"update_id" => 123_456, "message" => message}

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      # `Oban.Testing.assert_enqueued/1` does a JSON-containment match
      # on the `oban_jobs.args` column, so the message map is compared
      # structurally — no pin operator needed (and not supported here).
      assert_enqueued(Alethea.Repo,
        worker: TelegramMessageWorker,
        args: %{telegram_update_id: 123_456, message: message}
      )
    end
  end

  describe "update/2 — /start routing" do
    test "routes /start (no token) to TelegramOnboardingWorker with token=nil", %{conn: conn} do
      body = build_update(%{"text" => "/start"})

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      assert_enqueued(Alethea.Repo,
        worker: TelegramOnboardingWorker,
        args: %{telegram_update_id: 123_456, token: nil}
      )

      # The inbound worker is NOT enqueued for /start messages.
      refute_enqueued(Alethea.Repo, worker: TelegramMessageWorker)
    end

    test "extracts the token from /start <token> and passes it through to the worker", %{
      conn: conn
    } do
      body = build_update(%{"text" => "/start abc.def.ghi"})

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      assert_enqueued(Alethea.Repo,
        worker: TelegramOnboardingWorker,
        args: %{telegram_update_id: 123_456, token: "abc.def.ghi"}
      )
    end

    test "/START (uppercase) is NOT routed to onboarding — Telegram convention is case-sensitive",
         %{conn: conn} do
      # Telegram's `/start` command is case-sensitive. A `/START` is just
      # a regular text message — it falls through to TelegramMessageWorker.
      # (If we ever needed case-insensitive routing, that would be a
      # spec change, not a controller tweak.)
      body = build_update(%{"text" => "/START"})

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      assert_enqueued(Alethea.Repo, worker: TelegramMessageWorker)
      refute_enqueued(Alethea.Repo, worker: TelegramOnboardingWorker)
    end
  end

  describe "update/2 — malformed input (ack-and-drop)" do
    test "missing update_id → 200, no job enqueued (worker decides)", %{conn: conn} do
      body = %{"message" => %{"text" => "hello"}}

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      refute_enqueued(Alethea.Repo, worker: TelegramMessageWorker)
      refute_enqueued(Alethea.Repo, worker: TelegramOnboardingWorker)
    end

    test "missing message → 200, no job enqueued", %{conn: conn} do
      body = %{"update_id" => 123_456}

      conn = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn.status == 200

      refute_enqueued(Alethea.Repo, worker: TelegramMessageWorker)
      refute_enqueued(Alethea.Repo, worker: TelegramOnboardingWorker)
    end
  end

  describe "update/2 — 24h Oban unique on telegram_update_id (R-3)" do
    test "a second enqueue with the same telegram_update_id is silently dropped", %{conn: conn} do
      body = build_update(%{"text" => "hello"})

      # First dispatch — job inserted.
      conn1 = Phoenix.ConnTest.dispatch(conn, TelegramWebhookController, :post, :update, body)
      assert conn1.status == 200

      # Second dispatch with the SAME update_id — the controller returns
      # 200 (it has no way to know Oban will drop the job), but the Oban
      # unique constraint on `telegram_update_id` (24h period) silently
      # discards the duplicate so the worker doesn't process the same
      # Telegram update twice. Oban 2.x skips the insert entirely
      # (the second job is never persisted), so the Oban.Job table
      # has exactly one row after both dispatches.
      conn2 =
        Phoenix.ConnTest.dispatch(build_conn(), TelegramWebhookController, :post, :update, body)

      assert conn2.status == 200

      # Total row count is exactly 1 (the first job; the duplicate is
      # never inserted). The state of the surviving job is "available"
      # because the Oban config is `testing: :manual` (no engine
      # auto-processing). The worker column is stored as the bare
      # module name (`Alethea.Jobs.TelegramMessageWorker`), NOT the
      # `Elixir.Alethea.Jobs.TelegramMessageWorker` prefixed form that
      # some Ecto `dump` paths produce.
      row_count =
        Oban.Job
        |> where([j], j.worker == "Alethea.Jobs.TelegramMessageWorker")
        |> Alethea.Repo.aggregate(:count)

      assert row_count == 1

      available_count =
        Oban.Job
        |> where(
          [j],
          j.worker == "Alethea.Jobs.TelegramMessageWorker" and j.state == "available"
        )
        |> Alethea.Repo.aggregate(:count)

      assert available_count == 1
    end
  end

  # --- helpers ---

  defp build_update(message_overrides) do
    base_message = %{
      "message_id" => 1,
      "date" => 1_234_567_890,
      "chat" => %{"id" => 987_654, "type" => "private"},
      "text" => "hello"
    }

    message = Map.merge(base_message, message_overrides)
    %{"update_id" => 123_456, "message" => message}
  end
end
