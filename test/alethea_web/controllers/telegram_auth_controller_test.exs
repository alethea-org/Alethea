defmodule AletheaWeb.TelegramAuthControllerTest do
  @moduledoc """
  Tests for `AletheaWeb.TelegramAuthController` (C-4 wire-up skeleton).

  PR #2 ships this controller as a 200+log skeleton so the route is
  wired and the smoke test passes. The full `consume/2` semantics
  (deep-link + 6-digit verification, single-use, rate-limit, patient
  binding, welcome emission) land in PR #4 — TASK-4-4. See
  `lib/alethea_web/controllers/telegram_auth_controller.ex` for the
  design boundary.

  ## Test wiring

  The controller is dispatched directly via `Phoenix.ConnTest.dispatch/5`
  because TASK-2-5 (router pipeline) is not yet wired. The
  `TelegramSecretToken` plug (TASK-2-2) is in the router pipeline, NOT
  the controller pipeline — the same convention as
  `TelegramWebhookControllerTest`. The 401 path is exercised by the
  plug's tests; the auth controller assumes the plug has already
  validated the secret-token path that fronts this route in
  production. (The `/webhooks/telegram/auth` route is a public web
  entry point and is NOT behind the `TelegramSecretToken` plug —
  the design §8 rationale documents that the auth route is a
  short-lived patient-facing URL with a 10-minute TTL token, not
  a Telegram-signed POST. The plug-vs-no-plug decision for this
  route is locked in design §8 and the router pipeline in TASK-2-5.)
  """

  use AletheaWeb.ConnCase, async: false

  alias AletheaWeb.TelegramAuthController

  @moduletag :telegram

  describe "consume/2 — skeleton" do
    test "returns 200 with empty body regardless of params (smoke)", %{conn: conn} do
      conn =
        Phoenix.ConnTest.dispatch(conn, TelegramAuthController, :get, :consume, %{})

      assert conn.status == 200
      assert conn.resp_body == ""
    end

    test "returns 200 with empty body for a deep-link-style payload (start=<token>)", %{
      conn: conn
    } do
      # The full controller (PR #4) will read the `start` param and
      # verify the token via DeepLinkToken.valid_format?/1 + bind
      # the patient via Accounts.bind_patient_to_chat/2. The skeleton
      # ignores the params and just acks.
      conn =
        Phoenix.ConnTest.dispatch(
          conn,
          TelegramAuthController,
          :get,
          :consume,
          %{"start" => "abc.def.ghi-very-long-deep-link-token"}
        )

      assert conn.status == 200
    end

    test "returns 200 with empty body for a six-digit-code payload (code=<6digit>)", %{conn: conn} do
      # The full controller (PR #4) will read the `code` param, look
      # up the PatientAuthCode, and enforce single-use + TTL.
      conn =
        Phoenix.ConnTest.dispatch(
          conn,
          TelegramAuthController,
          :get,
          :consume,
          %{"code" => "123456"}
        )

      assert conn.status == 200
    end
  end
end
