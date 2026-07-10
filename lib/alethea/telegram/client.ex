defmodule Alethea.Telegram.Client do
  @moduledoc """
  Behaviour contract for Telegram Bot API clients (C-7 outbound).

  The Telegram outbound worker (`Alethea.Jobs.TelegramOutboundWorker`,
  PR #3a) calls `Alethea.Telegram.Client.send_message/2` to deliver a
  reply to a patient's chat. The actual transport (HTTP POST to
  `api.telegram.org/bot<token>/sendMessage`) is hidden behind the
  behaviour so the worker body is decoupled from the wire format.

  ## Adapters

    - `Alethea.Telegram.Client.Fake` — `:test` and `:dev` adapter that
      accumulates sends in an ETS table. Tests assert on the
      accumulated sends to verify the outbound flow.
    - `Alethea.Telegram.Client.Req` — production adapter (lands in
      PR #3a). Uses `Req` to POST to the Telegram Bot API.

  The adapter is selected at compile-time by reading
  `Application.get_env(:alethea, :telegram_client)` (defaults to
  `Alethea.Telegram.Client.Fake` for safety — a missing config
  degrades to the no-op adapter, NOT a runtime crash). Production
  deployments set the config explicitly:

      config :alethea, :telegram_client, Alethea.Telegram.Client.Req

  ## Contract

  The behaviour is intentionally minimal. Anything beyond a single
  text message (inline keyboards, reply markup, media uploads) is
  out of scope for the v1 gateway — the v2 Telegram Bot API surface
  is significantly larger but the journaling use case only needs
  text. Future capabilities (e.g. callback queries for the crisis
  path) will widen the behaviour in a follow-up PR.

  ## PHI hygiene (R-1)

  The `chat_id` is the **plaintext** Telegram chat identifier — the
  raw integer Telegram's API uses. Implementations must NOT log
  the `text` argument (it is the patient's own words) and must NOT
  log the response body (it echoes the message back). The outbound
  worker (PR #3a) is responsible for HMAC-hashing the `chat_id` to
  `chat_id_hash` BEFORE this behaviour is called, so the adapter
  only ever sees the plaintext at the API edge.
  """

  @typedoc """
  Telegram chat identifier (the plaintext integer Telegram assigns
  to each chat). 64-bit signed integer in practice; the type
  accepts any positive integer for forward-compat.
  """
  @type chat_id :: pos_integer()

  @typedoc """
  Text body of the outbound message. The patient is the author —
  implementations must NOT log this value at any layer.
  """
  @type message_text :: String.t()

  @typedoc """
  Telegram's monotonic `message_id` for the delivered message, used
  by the outbound worker to record the dispatch in the
  `JournalEntry.outbound_message_id` column. `nil` when the
  transport cannot return one (e.g. the Fake adapter in tests).
  """
  @type telegram_message_id :: pos_integer() | nil

  @doc """
  Sends `text` to the chat identified by `chat_id`. Returns
  `{:ok, telegram_message_id}` on success (the id is `nil` if the
  transport does not return one), or `{:error, term}` on failure.
  The caller (`Alethea.Jobs.TelegramOutboundWorker`) is responsible
  for the 429 retry + dead-letter + crisis-bypass queue logic;
  this callback is the synchronous "send and ack" surface.
  """
  @callback send_message(chat_id(), message_text()) ::
              {:ok, telegram_message_id()} | {:error, term()}
end
