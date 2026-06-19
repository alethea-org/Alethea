defmodule AletheaWeb.TelegramAuthController do
  @moduledoc """
  Web auth entrypoint for Telegram patient onboarding (C-4 wire-up only).

  Receives `GET /webhooks/telegram/auth?start=<token>` (deep-link fallback)
  and `GET /webhooks/telegram/auth?code=<6digit>` (six-digit code fallback)
  from a patient's web browser. In PR #2, this controller is a **skeleton**
  — it returns `200 OK` with an empty body and logs the request so the
  route is wired and the smoke test passes. The full `consume/2` semantics
  (deep-link token verification via `DeepLinkToken.valid_format?/1`, six-digit
  code lookup, single-use enforcement, rate-limit guard, patient binding
  via `Accounts.bind_patient_to_chat/2`, and welcome emission through
  `TelegramOutboundWorker`) land in **PR #4 — TASK-4-4**.

  The six-digit-code-via-`/start` rejection (a `/start` payload with a
  6-digit code instead of a deep-link token) lives in the
  `TelegramOnboardingWorker` (PR #3a), not here — this controller is the
  web entry point only.

  ## Why a skeleton in PR #2

  PR #2 wires the wire (webhook entrypoint, controllers, Oban queues,
  Pacer supervision, column rename). It does NOT yet wire the
  onboarding flow — that depends on `PatientAuthCode` (PR #4) and
  the full Oban workers (PR #3a). The skeleton's job is to land the
  route so the rest of the change can build on it without a
  re-slicing churn.

  ## PHI hygiene (R-1)

  The skeleton's log line does NOT include the `start` or `code` param
  values. The full controller (PR #4) will hash the deep-link token
  before any log line, and the six-digit code is short-lived (10 min
  TTL) so it must never appear in logs at any layer.
  """

  use AletheaWeb, :controller

  require Logger

  @doc """
  Stub entrypoint. Returns `200 OK` with an empty body and logs the
  request at INFO level. The full flow (verification, binding, welcome)
  lands in PR #4 — see `@moduledoc` for the design boundary.
  """
  def consume(conn, _params) do
    Logger.info("Telegram auth request received (skeleton — full flow lands in PR #4 TASK-4-4)")

    send_resp(conn, 200, "")
  end
end
