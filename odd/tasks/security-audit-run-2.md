# Security audit run-2: fix the 5 priority leads

Objective: fix the five highest-priority `needs_validation` leads from the deep security audit run-2 (`~/security-audit-skill/alethea/run-2/NEEDS-VALIDATION.md`, items 1-5). Branch `fix/security-audit-run-2` (worktree `Alethea-worktrees/security-audit-run-2-fixes`), from `main` at `b629409`. Delivery: ask-on-risk. Runner: `mix test` (Postgres + pgvector).

## Specs

- **S1 — AI summaries encrypted under the patient key.** Lead 1, fingerprint `alethea/clinical/summary:summary_text-plaintext-outside-patient-dek`: "AI clinical session/weekly summaries are stored in plaintext, outside patient-level encryption". `clinical_summaries.summary_text` must be stored encrypted under the patient DEK (like `Message` and `RunningSummary.Snapshot`), existing rows migrated, and every reader decrypts. Acceptance: no plaintext summary text in `clinical_summaries` after write or migration; destroying the patient key makes summaries unreadable; dashboard still shows summaries.
- **S2 — No plaintext reply text in dead letters.** Lead 2, fingerprint `telegram-outbound-dead-letter-plaintext-reply-text`: "Failed and ambiguous Telegram replies are copied in plaintext to foundation_outbound_dead_letters and never erased". Dead letters must not store the reply body in clear; existing plaintext rows are cleared. Acceptance: a dead-lettered reply leaves no plaintext body in `foundation_outbound_dead_letters`; operators can still identify the failed message.
- **S3 — Weekly report never logs clinical text.** Lead 3, fingerprint `weekly_report_worker.ex:perform:inspect-summary-changeset-phi-log`: "WeeklyReportWorker logs and returns to Oban the full Summary changeset, including the AI weekly clinical narrative". Use the existing `AletheaJobs.SafeReason` for log and returned error, mark `summary_text` `redact: true`, and range-check scores before persistence. Acceptance: an out-of-range score produces a log line and Oban error with no summary text.
- **S4 — Crisis intake does not wait behind LLM replies.** Lead 4, fingerprint `alethea/oban/telegram_inbound-shared-by-llm-burst-and-crisis-intake`: "LLM-bound burst reply jobs share the telegram_inbound queue with deterministic crisis intake". `TelegramBurstReplyWorker` runs on its own queue so inbound/crisis intake slots are never held by LLM calls. Acceptance: burst jobs are enqueued on a queue other than `telegram_inbound`.
- **S5 — No trigger delivery after /pausa or archive.** Lead 5, fingerprint `trigger-outbound-status-denylist-misses-patient-pause`: "Fired trigger messages are still delivered after the patient sends /pausa (and after a fired one-shot is archived)". Delivery must use an allowlist (status `active` or `fired`, `archived_at` nil) instead of a denylist. Acceptance: a pending trigger message whose trigger is `paused_by_patient` or archived is not sent.

## Tasks

- [ ] T1 — S1 + S3 (summary.ex shared). Route: delegated writer A (context backstop; parallel with T2). Risk: item 1 (migration of stored data), item 2 (encryption). Commit: —
- [ ] T2 — S2 + S5 (telegram_outbound_worker.ex shared). Route: delegated writer B (parallel with T1). Risk: item 1 (clears stored data). Commit: —
- [x] T3 — S4. Route: inline (config + worker queue, ~10 lines). Risk: item 4 (queue topology). Commit: b46e546

## Log

- **L1** (2026-11-27, user): "cerremos los 3 pendientes y después vamos con los 5"
- **L2** (2026-11-27): the 5 = REPORT.md section 5 items 1-5 of audit run-2. Writers are delegated under the long-session context backstop, with disjoint edit surfaces; T3 inline.
- **L3** (2026-11-27): T3 RED: 2 new queue tests failed (job.queue "telegram_inbound"). GREEN: TelegramBurstReplyWorker on `telegram_reply: 10`; `mix test test/alethea/jobs`: 308 passed; compile --warnings-as-errors and format clean. Audit run-2 closed complete (85/85 agents, 20 needs_validation, 3 rejected).
