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
       - `:ok` → `Accounts.consume_patient_auth_code(token, chat_id_hash, kind: kind)`
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

  alias Alethea.Accounts, as: LegacyAccounts
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
        handle_verified(token, kind, chat_id, chat_id_hash, hash_prefix)

      failure ->
        Logger.info("TelegramOnboardingWorker: rejected (#{failure}, hash_prefix=#{hash_prefix})")

        enqueue_reply(chat_id, chat_id_hash, failure_text(failure))
    end
  end

  defp handle_verified(token, kind, chat_id, chat_id_hash, hash_prefix) do
    case Accounts.consume_patient_auth_code(token, chat_id_hash, kind: kind) do
      {:ok, patient} ->
        Logger.info("TelegramOnboardingWorker: bound chat (hash_prefix=#{hash_prefix})")
        enqueue_reply(chat_id, chat_id_hash, welcome_text(patient), patient.id)

      {:error, reason} ->
        Logger.info(
          "TelegramOnboardingWorker: consume rejected (#{safe_error_reason(reason)}, hash_prefix=#{hash_prefix})"
        )

        enqueue_reply(chat_id, chat_id_hash, failure_text(reason))
    end
  end

  # ----------------------------------------------------------------
  # Outbound enqueue (REQ-C4-send-welcome-reply)
  # ----------------------------------------------------------------

  defp enqueue_reply(chat_id, chat_id_hash, body, patient_id \\ nil) do
    %{
      chat_id: chat_id,
      chat_id_hash: chat_id_hash,
      body: body,
      lane: :safe,
      patient_id: patient_id
    }
    |> TelegramOutboundWorker.new(queue: :telegram_outbound)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "TelegramOnboardingWorker: failed to enqueue welcome/reply " <>
            "(reason=#{safe_error_reason(reason)})"
        )

        :ok
    end
  end

  # PHI hygiene (R-1): never `inspect(reason)` wholesale.
  #   - On an `Oban.insert/1` failure `reason` is typically an
  #     `%Ecto.Changeset{}` whose `changes.args` carries the raw
  #     `chat_id`, full `chat_id_hash`, and message `body` — only the
  #     changeset's own validation errors (safe, structural) are
  #     logged.
  #   - On a `consume_patient_auth_code/3` failure `reason` can ALSO be
  #     a `%Ecto.Changeset{}` (the non-collision `:bind` failure
  #     branch), whose `changes` carries the full
  #     `telegram_chat_id_hash` in the clear — `inspect/1` on that
  #     changeset would leak it. Plain atom reasons (`:already_used`,
  #     `:chat_bound_to_other_patient`, etc.) carry no PHI and pass
  #     through unchanged.
  defp safe_error_reason(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  defp safe_error_reason({:error, reason}) when is_atom(reason), do: reason
  defp safe_error_reason(reason) when is_atom(reason), do: reason
  defp safe_error_reason(_other), do: "unknown reason"

  # ----------------------------------------------------------------
  # Copy (localized Spanish, per REQ-C4-* scenarios)
  # ----------------------------------------------------------------

  # REQ-W-welcome-text-resolution / REQ-W-name-interpolation: resolve
  # `professional.welcome_message || <system default>`, interpolating
  # the patient's first name (when known) into whichever template is
  # active. An explicit empty-string `welcome_message` is sent verbatim
  # (not falling back to the default) — only `nil` triggers the
  # fallback, matching `||`'s truthiness in Elixir.
  defp welcome_text(patient) do
    name = first_name(patient.profile_name)

    case custom_welcome_message(patient) do
      nil -> default_welcome_text(name)
      custom -> interpolate_welcome_name(custom, name)
    end
  end

  # REQ-W-preload-professional: `consume_patient_auth_code/3`'s
  # `{:ok, patient}` does not preload `:professional`, and even once
  # preloaded it would point at the FOUNDATION-namespace professional,
  # not the one a professional actually edits via `DashboardLive`'s
  # `save_welcome_message` event (`Alethea.Accounts.Professional`,
  # legacy table). Bridge to the legacy Patient first — the exact
  # pattern `TelegramMessageWorker`'s crisis branch already uses for
  # `crisis_message` — then preload `:professional` on that legacy
  # Patient via `LegacyAccounts.get_patient_with_professional/1`.
  #
  # Unlike the crisis branch (which hard-matches `{:ok, legacy_patient}`
  # because every message-pipeline patient is bound by then), a patient
  # created outside the lockstep legacy+foundation flow may have no
  # `legacy_patient_id` at all — fall back to the system default rather
  # than raise.
  defp custom_welcome_message(patient) do
    with {:ok, legacy_patient} <- Accounts.legacy_patient(patient),
         %{professional: %{welcome_message: message}} <-
           LegacyAccounts.get_patient_with_professional(legacy_patient.id) do
      message
    else
      # `:not_linked` is an EXPECTED state — not every foundation
      # patient has a legacy bridge yet — so it stays silent.
      :not_linked ->
        nil

      # Anything else (`{:error, :legacy_not_found}`, a missing/shape
      # mismatch on the legacy preload, etc.) means this patient IS
      # bound to a Telegram chat but the legacy bridge is broken —
      # that deserves operational visibility instead of a silent
      # fallback to the generic welcome copy. `patient.id` is an
      # internal identifier (UUID), not PHI.
      other ->
        Logger.warning(
          "TelegramOnboardingWorker: unexpected failure resolving custom welcome_message " <>
            "(patient_id=#{patient.id}, result=#{safe_error_reason(other)})"
        )

        nil
    end
  end

  defp default_welcome_text(nil), do: default_welcome_template()
  defp default_welcome_text(name), do: default_welcome_template(name)

  defp default_welcome_template do
    "¡Hola! Tu cuenta de Telegram fue vinculada correctamente. A partir de ahora podés escribirme por acá."
  end

  defp default_welcome_template(name) do
    "¡Hola, #{name}! Tu cuenta de Telegram fue vinculada correctamente. A partir de ahora podés escribirme por acá."
  end

  # When the name is unknown, every "%{name}" occurrence (there may be
  # more than one) is dropped along with its immediately adjacent
  # whitespace in a single regex pass, then the result is trimmed at
  # the edges only. This scopes the whitespace cleanup to the
  # placeholder's own vicinity — it must NEVER touch an unrelated
  # double space elsewhere in the professional's template, and it must
  # correctly collapse 0, 1, or multiple placeholder occurrences
  # without leaving a run of leftover spaces.
  defp interpolate_welcome_name(template, nil) do
    if template =~ "%{name}" do
      ~r/\s*%\{name\}\s*/
      |> Regex.replace(template, " ")
      |> String.trim()
    else
      template
    end
  end

  # A known name is being inserted, not removed, so no whitespace
  # scoping is needed — a plain substitution is safe (and a no-op when
  # the template has no placeholder).
  defp interpolate_welcome_name(template, name) do
    String.replace(template, "%{name}", name)
  end

  defp failure_text(:expired),
    do: "Tu link venció. Pedile a tu terapeuta uno nuevo."

  defp failure_text(:already_used),
    do: "Este link ya fue usado."

  defp failure_text(:rate_limited),
    do: "Demasiados intentos. Probá más tarde."

  defp failure_text(:chat_bound_to_other_patient),
    do: "Este Telegram ya está vinculado a otro paciente, contactá a tu psicólogo."

  # Catch-all: an unexpected/non-collision changeset error (or any
  # other unhandled shape) from `consume_patient_auth_code/3` falls
  # through to `{:error, changeset}` — currently unreachable in
  # practice, but without this clause it would crash with
  # `FunctionClauseError` instead of replying gracefully.
  defp failure_text(_other),
    do: "Ocurrió un error. Intentá de nuevo más tarde."

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
