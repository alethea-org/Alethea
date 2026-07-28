defmodule AletheaJobs.SafeReason do
  @moduledoc """
  PHI-safe logging helper for Oban worker error sites.

  Renders a persistence failure reason WITHOUT leaking
  `Ecto.Changeset.changes` — which may hold plaintext clinical content
  (e.g. `summary_text` on `Alethea.Clinical.Summary` — the
  AI-generated clinical summary; `body` on `messages`; `ai_response`
  on `ai_diagnoses`). For an `Ecto.Changeset`, only the field keys
  that FAILED validation are surfaced; the `changes` / `data` maps
  are intentionally omitted. Any other reason shape is rendered via
  `inspect/1` as-is (non-changeset reasons carry no PHI by shape —
  e.g. `:queue_full`, `:timeout`, plain error tuples).

  ## What this helper is — and is NOT

    - **YES**: a per-call helper that you apply explicitly at every
      `Logger.error/1`, `Logger.warning/1`, or `raise/1` site where the
      `reason` could be an `Ecto.Changeset`. The
      `session_timeout_worker.ex:180` `inspect(reason)` was the exact
      bug this helper fixes (R2 on #86 PR-1).

    - **NO**: a global Logger backend. There is NO configured
      `Logger.Backends.Console` redaction wrapper; this is a
      per-call function that callers MUST apply explicitly. A future
      improvement could centralize this either as a real Logger
      backend OR as a wrapper helper — that is a separate change. The
      current surgical fix puts `SafeReason.for_log/1` at every
      reason-logging site so a developer adding a new one sees the
      pattern in the surrounding code.

  ## Relationship to `TelegramOutboundWorker.LogRedactor`

  Similar pattern, different scope:

    - `Alethea.Telegram.LogRedactor` scrubs the 64-char lowercase-hex
      `chat_id_hash` shape out of arbitrary strings (PII correlation
      surface). It is also per-call (callers wrap log strings with
      `LogRedactor.prefix/1` or `LogRedactor.redact/1`).

    - `AletheaJobs.SafeReason.for_log/1` scrubs
      `Ecto.Changeset.changes` (clinical content surface). It is also
      per-call (callers wrap the `reason` before it lands in a log
      line or raised exception message).

  Either helper, if forgotten at a call site, leaks PHI. Use BOTH at
  every error site where both surfaces could be present (a
  `Changeset` whose `changes` includes `chat_id_hash`, for example).

  ## Origin

  Mirrors the helper originally introduced as a PRIVATE function in
  `Alethea.Jobs.TelegramMessageWorker` (#85 R1 fix — the inbound
  MatchError on Changeset that leaked via Oban `errors` column). The
  sibling R2 fixes on that same worker (crisis-outbound case wrap)
  reused the same private helper. Extracted here as a shared module
  so `AletheaJobs.SessionTimeoutWorker:180` (R2 #86 PR-1 fix, the
  `summary_text` PHI leak caught by `review-risk`'s bounded lens)
  can use it without duplicating the function definition.
  """

  @doc """
  Render a persistence failure reason in a PHI-safe way for logs / raised
  exception messages.

  ## Examples

      iex> changeset = %Ecto.Changeset{
      ...>   errors: [summary_text: {"can't be blank", [validation: :required]}]
      ...> }
      iex> AletheaJobs.SafeReason.for_log(changeset)
      "[:summary_text]"

      iex> changeset = %Ecto.Changeset{
      ...>   errors: [
      ...>     body: {"can't be blank", [validation: :required]},
      ...>     summary_text: {"too short", []}
      ...>   ]
      ...> }
      iex> AletheaJobs.SafeReason.for_log(changeset)
      "[:body, :summary_text]"

      iex> AletheaJobs.SafeReason.for_log(:timeout)
      ":timeout"

      iex> AletheaJobs.SafeReason.for_log({:error, :queue_full})
      "{:error, :queue_full}"
  """
  def for_log(%Ecto.Changeset{errors: errors}) do
    errors |> Keyword.keys() |> Enum.uniq() |> inspect()
  end

  def for_log(reason), do: inspect(reason)
end
