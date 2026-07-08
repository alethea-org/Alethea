defmodule Alethea.Jobs.TelegramOnboardingWorker do
  @moduledoc """
  Oban worker for the Telegram patient onboarding flow (C-4, PR #4).

  Binds a Telegram chat to a `Alethea.Foundation.Accounts.Patient` row
  using either a deep-link token (from `/start <token>`, via the
  webhook controller) or a six-digit / deep-link code submitted through
  the web fallback (via `AletheaWeb.TelegramAuthController.consume/2`).
  Both entry points enqueue this same worker so the bind logic lives
  in exactly one place.

  ## Args shape

      %{
        telegram_update_id: integer() | nil,  # nil for web-originated jobs
        token: binary() | nil,                # the code/token to redeem
        chat_id: pos_integer(),                # required — Telegram's chat id
        kind: "deep_link" | "six_digit",       # optional, defaults to "deep_link"
        ip: binary() | nil                     # optional, see @telegram_webhook_ip
      }

  ## Flow

    1. If `token` is `nil` (cold-open — the patient opened the chat
       without a professional pre-minted link), skip straight to the
       `:expired`-style rejection reply. There is nothing to verify.
    2. `Accounts.verify_patient_auth_code(token, ip, kind: kind)`:
       - `:ok` → `Accounts.consume_patient_auth_code(token, chat_id_hash)`
         atomically binds the patient and marks the code used.
         - `{:ok, patient}` → enqueue the personality-aware welcome.
         - `{:error, :chat_bound_to_other_patient}` → enqueue the
           collision reply (REQ-C4-reject-chat-bound-to-other-patient).
         - `{:error, :already_used}` → enqueue the already-used reply
           (a race between verify and consume).
       - `:expired` / `:already_used` / `:rate_limited` → enqueue the
         matching localized reply. No bind.

  ## Why the webhook path always uses `kind: "deep_link"`

  `/start` is the bot-conversation entry point; per
  `REQ-C4-six-digit-fallback`, a six-digit code is web-only. The
  webhook controller never sets `kind` in the args, so this worker
  defaults to `"deep_link"`. A patient who types `/start <6-digit
  code>` is naturally rejected: `verify_patient_auth_code/3` scopes
  its lookup to `(code, kind: "deep_link")`, and the six-digit row was
  minted with `kind: "six_digit"` — no row matches, so the result is
  the same as an unknown code (`:expired`). No special-casing needed.

  ## Why `ip: "telegram-webhook"` for the bot-conversation path

  Telegram's webhook delivers `/start` messages from Telegram's own
  relay servers, not the patient's device — there is no per-patient IP
  to rate-limit on at this layer. The sentinel constant scopes the
  rate limit to the auth-code ROW itself (5 attempts/hour for that
  SPECIFIC token, regardless of which Telegram relay IP delivered the
  message), which still protects against brute-forcing one token. The
  web fallback controller (`TelegramAuthController`) passes the real
  `conn.remote_ip`, which IS meaningful there.

  ## PHI hygiene (R-1)

  Log lines never include the raw `chat_id` or the full
  `chat_id_hash` — only `LogRedactor.prefix/1`'s 8-char correlation
  token, per the same pattern established in `TelegramMessageWorker`
  and `TelegramOutboundWorker` (PR #3a/#3b).
  """

  use Oban.Worker,
    queue: :telegram_inbound,
    max_attempts: 2

  require Logger

  alias Alethea.Foundation.Accounts
  alias Alethea.Jobs.TelegramOutboundWorker
  alias Alethea.Telegram.{ChatIdHash, LogRedactor}

  # Telegram's webhook delivers `/start` from its own relay, not the
  # patient's device — see moduledoc "Why ip: telegram-webhook" above.
  @telegram_webhook_ip "telegram-webhook"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    token = Map.get(args, "token")
    chat_id = Map.fetch!(args, "chat_id")
    kind = Map.get(args, "kind", "deep_link")
    ip = Map.get(args, "ip", @telegram_webhook_ip)

    chat_id_hash = ChatIdHash.hash(chat_id, pepper!())
    hash_prefix = LogRedactor.prefix(chat_id_hash)

    handle_token(token, kind, ip, chat_id, chat_id_hash, hash_prefix)

    :ok
  end

  # Cold-open: the patient sent `/start` with no token (no professional
  # pre-minted a link). There is nothing to verify; reply with the
  # same "get a new link" copy used for an unknown/expired token.
  defp handle_token(nil, _kind, _ip, chat_id, chat_id_hash, hash_prefix) do
    Logger.info(
      "TelegramOnboardingWorker: cold-open /start with no token (hash_prefix=#{hash_prefix})"
    )

    enqueue_reply(chat_id, chat_id_hash, failure_text(:expired))
  end

  defp handle_token(token, kind, ip, chat_id, chat_id_hash, hash_prefix) do
    case Accounts.verify_patient_auth_code(token, ip, kind: kind) do
      :ok ->
        handle_verified(token, chat_id, chat_id_hash, hash_prefix)

      failure ->
        Logger.info("TelegramOnboardingWorker: rejected (#{failure}, hash_prefix=#{hash_prefix})")

        enqueue_reply(chat_id, chat_id_hash, failure_text(failure))
    end
  end

  defp handle_verified(token, chat_id, chat_id_hash, hash_prefix) do
    case Accounts.consume_patient_auth_code(token, chat_id_hash) do
      {:ok, patient} ->
        Logger.info("TelegramOnboardingWorker: bound chat (hash_prefix=#{hash_prefix})")
        enqueue_reply(chat_id, chat_id_hash, welcome_text(patient))

      {:error, reason} ->
        Logger.info(
          "TelegramOnboardingWorker: consume rejected (#{reason}, hash_prefix=#{hash_prefix})"
        )

        enqueue_reply(chat_id, chat_id_hash, failure_text(reason))
    end
  end

  # ----------------------------------------------------------------
  # Outbound enqueue (REQ-C4-send-welcome-reply)
  # ----------------------------------------------------------------

  defp enqueue_reply(chat_id, chat_id_hash, body) do
    %{chat_id: chat_id, chat_id_hash: chat_id_hash, body: body, lane: :safe}
    |> TelegramOutboundWorker.new(queue: :telegram_outbound)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "TelegramOnboardingWorker: failed to enqueue welcome/reply " <>
            "(reason=#{inspect(reason)})"
        )

        :ok
    end
  end

  # ----------------------------------------------------------------
  # Copy (localized Spanish, per REQ-C4-* scenarios)
  # ----------------------------------------------------------------

  defp welcome_text(patient) do
    case first_name(Map.get(patient, :profile_name)) do
      nil ->
        "¡Hola! Tu cuenta de Telegram fue vinculada correctamente. A partir de ahora podés escribirme por acá."

      name ->
        "¡Hola, #{name}! Tu cuenta de Telegram fue vinculada correctamente. A partir de ahora podés escribirme por acá."
    end
  end

  defp failure_text(:expired),
    do: "Tu link venció. Pedile a tu terapeuta uno nuevo."

  defp failure_text(:already_used),
    do: "Este link ya fue usado."

  defp failure_text(:rate_limited),
    do: "Demasiados intentos. Probá más tarde."

  defp failure_text(:chat_bound_to_other_patient),
    do: "Este Telegram ya está vinculado a otro paciente, contactá a tu psicólogo."

  # ----------------------------------------------------------------
  # Pure helpers
  # ----------------------------------------------------------------

  defp first_name(nil), do: nil
  defp first_name(""), do: nil

  defp first_name(name) when is_binary(name) do
    case name |> String.trim() |> String.split(" ", trim: true) do
      [first | _] -> first
      [] -> nil
    end
  end

  defp pepper! do
    Application.fetch_env!(:alethea, :telegram_chat_id_pepper)
  end
end
