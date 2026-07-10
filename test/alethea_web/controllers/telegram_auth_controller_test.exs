defmodule AletheaWeb.TelegramAuthControllerTest do
  @moduledoc """
  Tests for `AletheaWeb.TelegramAuthController` (C-4 full; PR #4 /
  TASK-4-4).

  Covers the web fallback entrypoint: `GET /webhooks/telegram/auth`
  with `?start=<token>&chat_id=<id>` (deep-link) or
  `?code=<6digit>&chat_id=<id>` (six-digit). Both delegate to the SAME
  `Alethea.Jobs.TelegramOnboardingWorker` used by the bot-conversation
  `/start` path (TASK-4-3) — the bind logic lives in exactly one
  place. The controller's job is to ack 200 and enqueue with the
  right `kind` and the caller's real `conn.remote_ip` (meaningful
  here, unlike the bot webhook path).

  ## Test wiring

  The controller is dispatched directly via `Phoenix.ConnTest.dispatch/5`
  because TASK-2-5's router pipeline puts this route behind `:api`,
  not a controller-level plug. See
  `lib/alethea_web/controllers/telegram_auth_controller.ex` for the
  design boundary.
  """

  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  alias Alethea.Jobs.TelegramOnboardingWorker
  alias AletheaWeb.TelegramAuthController

  @moduletag :telegram

  setup do
    Alethea.Repo.delete_all(Oban.Job)
    :ok
  end

  describe "consume/2 — deep-link (?start=<token>&chat_id=<id>)" do
    test "enqueues the onboarding worker with kind: deep_link and the real remote_ip", %{
      conn: conn
    } do
      conn =
        Phoenix.ConnTest.dispatch(
          conn,
          TelegramAuthController,
          :get,
          :consume,
          %{"start" => "abc.def.ghi-very-long-deep-link-token", "chat_id" => "9001"}
        )

      assert conn.status == 200

      assert_enqueued(
        worker: TelegramOnboardingWorker,
        args: %{
          token: "abc.def.ghi-very-long-deep-link-token",
          kind: "deep_link",
          chat_id: 9001
        }
      )

      [job] = all_enqueued(worker: TelegramOnboardingWorker)
      assert job.args["ip"] == "127.0.0.1"
    end
  end

  describe "consume/2 — six-digit (?code=<6digit>&chat_id=<id>)" do
    test "enqueues the onboarding worker with kind: six_digit", %{conn: conn} do
      conn =
        Phoenix.ConnTest.dispatch(
          conn,
          TelegramAuthController,
          :get,
          :consume,
          %{"code" => "482915", "chat_id" => "9001"}
        )

      assert conn.status == 200

      assert_enqueued(
        worker: TelegramOnboardingWorker,
        args: %{token: "482915", kind: "six_digit", chat_id: 9001}
      )
    end
  end

  describe "consume/2 — malformed input (ack-and-drop, same convention as the webhook controller)" do
    test "returns 200 with empty body regardless of params (smoke)", %{conn: conn} do
      conn = Phoenix.ConnTest.dispatch(conn, TelegramAuthController, :get, :consume, %{})

      assert conn.status == 200
      assert conn.resp_body == ""
      refute_enqueued(worker: TelegramOnboardingWorker)
    end

    test "start without chat_id acks but does not enqueue", %{conn: conn} do
      conn =
        Phoenix.ConnTest.dispatch(conn, TelegramAuthController, :get, :consume, %{
          "start" => "abc.def.ghi-very-long-deep-link-token"
        })

      assert conn.status == 200
      refute_enqueued(worker: TelegramOnboardingWorker)
    end

    test "code without chat_id acks but does not enqueue", %{conn: conn} do
      conn =
        Phoenix.ConnTest.dispatch(conn, TelegramAuthController, :get, :consume, %{
          "code" => "123456"
        })

      assert conn.status == 200
      refute_enqueued(worker: TelegramOnboardingWorker)
    end

    test "non-numeric chat_id acks but does not enqueue", %{conn: conn} do
      conn =
        Phoenix.ConnTest.dispatch(conn, TelegramAuthController, :get, :consume, %{
          "start" => "abc.def.ghi-very-long-deep-link-token",
          "chat_id" => "not-a-number"
        })

      assert conn.status == 200
      refute_enqueued(worker: TelegramOnboardingWorker)
    end
  end

  describe "consume/2 — six_digit code cannot be redeemed via /start (REQ-C4-six-digit-fallback)" do
    test "a code submitted through ?start= is always scoped to kind: deep_link", %{conn: conn} do
      # A patient (or a bug) submitting a six-digit-looking value via
      # `?start=` still gets `kind: "deep_link"` — the controller
      # never inspects the VALUE, only which query param carried it.
      # A row minted as kind: "six_digit" will not match a
      # kind: "deep_link" lookup downstream (worker/context contract),
      # so this is rejected without any special-casing here.
      conn =
        Phoenix.ConnTest.dispatch(conn, TelegramAuthController, :get, :consume, %{
          "start" => "482915",
          "chat_id" => "9001"
        })

      assert conn.status == 200

      assert_enqueued(
        worker: TelegramOnboardingWorker,
        args: %{token: "482915", kind: "deep_link", chat_id: 9001}
      )
    end
  end
end
