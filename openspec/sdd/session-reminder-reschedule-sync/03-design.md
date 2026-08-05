# Design — session-reminder-reschedule-sync (#102)

**Approach:** cancel-only. On a successful patient schedule change in `DashboardLive`, cancel the stale pending `SessionReminderWorker` job(s) for that patient. No re-enqueue at schedule-change time (plaintext `chat_id` absent in professional context); the next inbound Telegram message re-enqueues for the new schedule via the untouched `schedule_session_reminder/3` path.

## THE ID-MATCHING QUESTION — RESOLVED, no mismatch

The ids match. No mapping needed.

- Reminder job args carry `patient_id: legacy_patient.id` — `telegram_message_worker.ex:423`.
- `legacy_patient` is an `Alethea.Accounts.Patient` — `telegram_message_worker.ex:137-138`.
- Legacy `Patient` primary key is `:binary_id` (UUID string) — `accounts/patient.ex:5`.
- `DashboardLive.selected_patient` is that same legacy `Patient` struct: `update_patient_session_schedule(%Patient{} = patient, …)` (`accounts.ex:198`); the handler passes `socket.assigns.selected_patient` (`dashboard_live.ex:126,146`).

⇒ `DashboardLive`'s `patient.id` (== `updated_patient.id`) is the **same legacy binary_id** stored in `args->>'patient_id'`. Both UUID strings; string-to-string comparison, no cast/mapping. (The outbound worker's `patient_id` is the *foundation* UUID — irrelevant here; reminder args deliberately use the legacy id.)

## Data flow

```
DashboardLive.handle_event("save_session_schedule")  [dashboard_live.ex:146 non-mock]
  └─ Accounts.update_patient_session_schedule/3  {:ok, updated_patient}   (stays Oban-free — accounts.ex:198)
       └─ SessionReminderWorker.cancel_pending(updated_patient.id)   [NEW, best-effort]
            └─ Oban.cancel_all_jobs(query)  →  {:ok, count}
```

## Decisions (ADR)

**D1 — cancel-only vs reschedule (DECIDED).** Reschedule-in-place needs plaintext `chat_id`, which exists only during a live inbound message (`telegram_message_worker.ex:176-183`), never in the professional `DashboardLive` context. Cancel-only accepts a transient gap until the next inbound re-enqueues — same tradeoff #97 made. Supersedes archived `03-design.md:117` "acceptable" note.

**D2 — home: `cancel_pending/1` on `AletheaJobs.SessionReminderWorker`** (not a sibling). The worker already owns its `queue: :sessions`, `unique` dedup key, and worker-string; colocating cancel keeps the "find my own pending jobs" query next to the enqueue-shape knowledge it depends on. Rejected a new sibling module (no independent responsibility).

**D3 — direct `Oban.cancel_all_jobs/1`, NOT a mockable wrapper.** `OutboundEnqueue` exists only to simulate `{:error, :queue_full}`, an insert failure Oban OSS never emits naturally. Cancel has no such un-observable failure: with Oban `testing: :manual` a test enqueues a real job and asserts the real cancelled row. A Mox seam would add indirection with zero test-reachability gain. (Justified divergence from the `OutboundEnqueue` precedent.)

**D4 — cancel-all is safe.** `unique: [keys: [:patient_id, :session_date], period: :infinity]` (`session_reminder_worker.ex:30`) guarantees ≤1 pending row per (patient, session_date); `cancel_all` scoped by patient is correct even if multiple future session_dates ever coexist.

## The cancel query

```elixir
# in AletheaJobs.SessionReminderWorker
import Ecto.Query

@spec cancel_pending(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
def cancel_pending(patient_id) do
  query =
    from j in Oban.Job,
      where: j.worker == "AletheaJobs.SessionReminderWorker",
      where: j.state in ["scheduled", "available", "retryable"],
      where: fragment("? ->> 'patient_id' = ?", j.args, ^to_string(patient_id))

  Oban.cancel_all_jobs(query)   # Oban 2.22.1 → {:ok, count}
end
```

- Oban stores `worker` without the `Elixir.` prefix ⇒ literal `"AletheaJobs.SessionReminderWorker"` (a test pins this against a real enqueued job).
- `args->>'patient_id'` is JSON text; `patient_id` is already a UUID string, `to_string/1` is defensive. No `::uuid` cast — both sides text.
- States `["scheduled","available","retryable"]` cover the pending reminder before AND between run attempts. **`retryable` added post-judgment-day (3/3 convergent finding):** a reminder that fired, raised, and awaits a retry (`max_attempts: 3`) would otherwise survive the cancel and deliver the stale reminder. `executing` is intentionally excluded (an in-flight send cannot be recalled). `cancel_pending/1` also carries an `@doc` authorization note: it scopes only by `patient_id`, so callers MUST pre-authorize the id (the sole caller resolves it via `Accounts.get_patient_for_professional/2`).

## Judgment-day accepted items (documented, not fixed)

- **TOCTOU race:** an inbound message that read the old schedule could enqueue a stale reminder just after `cancel_pending` runs. Inherent to enqueue-at-interaction + cancel; low probability; self-heals on the next inbound. Accepted.
- **No audit trail for the cancel:** unlike patient-data access, cancelling an internal reminder job writes no `Accounts.log_action` row. Accepted (internal job cleanup, not a clinical-data access event).

## Call-site & error handling — `dashboard_live.ex:148` (`{:ok, updated_patient}` branch only)

Best-effort: a cancel failure must NOT break the save UX (the schedule DID persist). Wrap, log, always show the success flash.

> **Implementation deviation (accepted):** the original `case {:ok,_}/{:error,_}` shape does NOT compile under Elixir 1.20's set-theoretic type checker with `--warnings-as-errors` — `Oban.cancel_all_jobs/2`'s `@spec` is `{:ok, non_neg_integer()}` (verified `deps/oban/lib/oban.ex:1475`), so the `{:error, _}` clause is statically unreachable dead code. The real failure mode is a *raised* exception (e.g. DB down), so the call site uses `try/rescue` and `cancel_pending/1`'s `@spec` is narrowed to `{:ok, non_neg_integer()}`. Same best-effort intent.

```elixir
{:ok, updated_patient} ->
  try do
    AletheaJobs.SessionReminderWorker.cancel_pending(updated_patient.id)
  rescue
    error ->
      Logger.warning("save_session_schedule: reminder cancel failed " <>
        "(patient_id=#{updated_patient.id}, reason=#{inspect(error)})")
  end
  # existing: list_patients, put_flash(:info, ...), assigns  (dashboard_live.ex:159-164)
```

- Mock branch (`dashboard_live.ex:130-144`) untouched (no real Oban, ids aren't UUIDs).
- `patient_id` in the log is a legacy DB id, not PHI (no chat_id/hash) — consistent with existing dashboard logging.

## Test seams (Oban `testing: :manual`)

1. **cancel happy path:** enqueue a real `SessionReminderWorker` job (future `scheduled_at`) for patient A; `cancel_pending(A.id)`; assert row `state == "cancelled"` and `{:ok, 1}`.
2. **scoping:** enqueue reminders for A and B; `cancel_pending(A.id)`; assert A cancelled, B still `"scheduled"`.
3. **worker-string pin:** read the enqueued job's `worker` field and assert it equals the literal in the query (guards a future rename).
4. **call-site:** render `DashboardLive`, enqueue a reminder for the selected patient, fire `save_session_schedule`, assert the pending reminder is cancelled and the success flash present.
5. **best-effort (optional):** force the cancel error path and assert the save still returns `{:noreply, …}` with the info flash.

## Risks

- Oban stored worker-string form is asserted-but-not-yet-observed here; test #3 pins it — a future rename would silently cancel nothing (fail-open). Low severity (best-effort nudge).
- Best-effort cancel: a cancel failure leaves a stale reminder that could fire before the next inbound re-enqueue (same transient-gap tradeoff as #97).
- Non-`DashboardLive` schedule-mutation paths remain unguarded (proposal non-goal / follow-up).
