defmodule AletheaWeb.TelegramAuthController do
  @moduledoc """
  Web auth entrypoint for Telegram patient onboarding (C-4 full,
  PR #4 / TASK-4-4).

  Receives `GET /webhooks/telegram/auth?start=<token>&chat_id=<id>`
  (deep-link web fallback) and
  `GET /webhooks/telegram/auth?code=<6digit>&chat_id=<id>` (six-digit
  web fallback) from a patient's browser.

  ## Why it enqueues the SAME worker as `/start`

  `Alethea.Jobs.TelegramOnboardingWorker` (TASK-4-3) already implements
  the full verify → consume → welcome/reject flow for the bot-conversation
  `/start <token>` path. Rather than duplicating that logic here, this
  controller enqueues the identical worker with an explicit `kind:` and
  the request's real `chat_id`/`ip` — the bind logic lives in exactly
  one place, and this controller's only job is to ack fast and
  translate the two query-param shapes into the worker's args.

  ## `chat_id` is required

  Unlike the bot webhook (where Telegram delivers `chat.id` in the
  Update payload), a browser GET has no inherent Telegram chat
  identity — the invite/fallback web page (out of scope for this
  change) is responsible for collecting the patient's `chat_id` and
  passing it as a query param. Per `REQ-C4-six-digit-fallback`'s own
  scenario (`?code=482915&chat_id=9001`), `chat_id` is part of this
  controller's contract for both paths.

  Malformed input (missing `chat_id`, a non-numeric `chat_id`, or
  neither `start` nor `code`) is **ack-and-drop**: always 200, no job
  enqueued. Same convention as `TelegramWebhookController` — never
  4xx a public webhook-adjacent endpoint.

  ## Why `kind:` is set by WHICH param carried the value, not the value's shape

  A six-digit-looking string submitted via `?start=` still gets
  `kind: "deep_link"` (REQ-C4-six-digit-fallback — six-digit codes are
  web-only, but the WEB path itself is `?code=`, not `?start=`). The
  kind-scoped lookup in `PatientAuthCode.verify_patient_auth_code/3`
  naturally rejects a mismatched kind (a row minted `kind: "six_digit"`
  never matches a `kind: "deep_link"` lookup) — no special-casing
  needed here.

  ## PHI hygiene (R-1)

  No log line includes `chat_id`, `start`, or `code` param values.
  """

  use AletheaWeb, :controller

  require Logger

  alias Alethea.Jobs.TelegramOnboardingWorker

  @doc """
  Enqueues `TelegramOnboardingWorker` for a deep-link or six-digit web
  fallback request and always returns `200 OK` with an empty body.
  """
  def consume(conn, %{"start" => token, "chat_id" => chat_id_param}) do
    process(conn, token, "deep_link", chat_id_param)
  end

  def consume(conn, %{"code" => code, "chat_id" => chat_id_param}) do
    process(conn, code, "six_digit", chat_id_param)
  end

  def consume(conn, _params) do
    Logger.info(
      "TelegramAuthController: request missing chat_id or a recognized param — ack-and-drop"
    )

    send_resp(conn, 200, "")
  end

  defp process(conn, token, kind, chat_id_param) do
    case parse_chat_id(chat_id_param) do
      {:ok, chat_id} ->
        enqueue_onboarding(token, kind, chat_id, remote_ip(conn))

      :error ->
        Logger.info("TelegramAuthController: non-numeric chat_id — ack-and-drop")
    end

    send_resp(conn, 200, "")
  end

  defp enqueue_onboarding(token, kind, chat_id, ip) do
    %{token: token, kind: kind, chat_id: chat_id, ip: ip}
    |> TelegramOnboardingWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "TelegramAuthController: failed to enqueue onboarding worker " <>
            "(reason=#{safe_error_reason(reason)})"
        )

        :ok
    end
  end

  # PHI hygiene (R-1): never `inspect(reason)` wholesale — on an
  # `Oban.insert/1` failure `reason` is typically an `%Ecto.Changeset{}`
  # whose `changes.args` carries the raw `chat_id` and `token`. Only
  # the changeset's own validation errors (safe, structural) are
  # logged.
  defp safe_error_reason(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  defp safe_error_reason(_other), do: "unknown reason"

  defp parse_chat_id(chat_id) when is_integer(chat_id) and chat_id > 0, do: {:ok, chat_id}

  defp parse_chat_id(chat_id) when is_binary(chat_id) do
    case Integer.parse(chat_id) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_chat_id(_), do: :error

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
