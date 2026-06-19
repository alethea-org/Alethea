defmodule AletheaWeb.TelegramWebhookController do
  @moduledoc """
  Inbound Telegram webhook controller (C-1, REQ-C1-webhook-*).

  Receives a Telegram `Update` JSON via `POST /webhooks/telegram` and:

    1. Returns 200 immediately — **latency-critical fast-ack**. Telegram
       retries if no 200 arrives within ~10 s, so the controller must
       ack before doing any heavy work.
    2. Enqueues an Oban job on `:telegram_inbound`:
       * `Alethea.Jobs.TelegramMessageWorker` for non-`/start` messages
       * `Alethea.Jobs.TelegramOnboardingWorker` for `/start <token>` (and
         `/start` with no token, where `token` is `nil`).
    3. Always returns 200 — malformed input (missing `update_id` or
       `message`) is **ack-and-drop**, NOT a 4xx. A 4xx would cause
       Telegram to retry-spam a malformed payload we cannot process.

  The actual clinical round-trip (PR #3a) and the onboarding binding
  (PR #4) happen in the workers. The controller's job is to
  acknowledge + enqueue.

  ## Auth (defense-in-depth)

  The `TelegramSecretToken` plug (`lib/alethea_web/plugs/telegram_secret_token.ex`,
  TASK-2-2) validates the `X-Telegram-Bot-Api-Secret-Token` header
  BEFORE this controller is invoked. The controller does **not**
  re-validate the secret token — that is the plug's job, and doing it
  twice is wasted work + a footgun if the two implementations diverge.
  If the secret token is invalid, the plug returns 401 and this
  controller is never called.

  ## Idempotency (R-3)

  `TelegramMessageWorker` is configured with
  `unique: [period: 86_400, keys: [:telegram_update_id]]` — a 24 h
  Oban unique on the `update_id`. Telegram's `update_id` is a
  monotonic counter per bot, so the same value can only be re-used
  by a Telegram-side replay. A duplicate enqueue within 24 h is
  silently dropped by Oban (the controller still returns 200; it has
  no way to know Oban will drop the job).

  ## PHI hygiene (R-1)

  The args map carries the raw `chat_id` (Telegram's API delivers it
  in plaintext). The controller does **not** log the body. The worker
  (PR #3a) is responsible for HMAC-hashing the `chat_id` via
  `Alethea.Telegram.ChatIdHash.hash/2` before any DB lookup or log
  line. The `update_id` is safe to log (Telegram's monotonic counter,
  not patient data) but the controller does not log it either, to
  keep the controller's behavior uniform and avoid accidental leaks.
  """

  use AletheaWeb, :controller

  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOnboardingWorker}

  @doc """
  Receives a Telegram `Update` and enqueues the appropriate worker.
  Always returns 200.
  """
  # 1) `/start` (with or without a token) → TelegramOnboardingWorker.
  #    Pattern match is case-sensitive on `/start` (Telegram convention).
  def update(
        conn,
        %{"update_id" => update_id, "message" => %{"text" => "/start" <> rest}}
      )
      when is_integer(update_id) do
    token =
      rest
      |> String.trim_leading()
      |> empty_to_nil()

    enqueue_onboarding(update_id, token)
    send_resp(conn, 200, "")
  end

  # 2) Any other text message → TelegramMessageWorker.
  def update(conn, %{"update_id" => update_id, "message" => message})
      when is_integer(update_id) do
    enqueue_message(update_id, message)
    send_resp(conn, 200, "")
  end

  # 3) Malformed input (missing update_id or message) → 200 ack-and-drop.
  def update(conn, _body) do
    send_resp(conn, 200, "")
  end

  # Telegram's `/start` with no token yields `rest = ""` (or pure whitespace
  # if Telegram ever changes the format). Normalize to `nil` so the worker
  # can pattern-match on a single shape: `token: binary() | nil`.
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(ws) when is_binary(ws), do: String.trim(ws)

  defp enqueue_message(update_id, message) do
    %{telegram_update_id: update_id, message: message}
    |> TelegramMessageWorker.new()
    |> Oban.insert()
  end

  defp enqueue_onboarding(update_id, token) do
    %{telegram_update_id: update_id, token: token}
    |> TelegramOnboardingWorker.new()
    |> Oban.insert()
  end
end
