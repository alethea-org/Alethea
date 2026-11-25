# Security audit run-1 fixes

Objective: fix the 7 `needs_validation` leads from security audit run-1 (`~/security-audit-skill/alethea/run-1/NEEDS-VALIDATION.md`, source ref c772941).
Branch: `fix/security-audit-run-1` (worktree `Alethea-worktrees/security-audit-fixes`, base `origin/main` c772941). Delivery: ask-on-risk. Runner: `mix test` (ExUnit, local Postgres; use a distinct `MIX_TEST_PARTITION` per parallel writer).

## Specs

- **S1 — Oban dashboard is admin-only.** Lead `alethea:oban_dashboard_live:missing-require-admin-cross-tenant-job-access`. `/admin/oban-dashboard` must only be reachable by professionals that pass `:require_admin` (ADMIN_EMAILS). A non-admin entitled professional gets the same 404/redirect as other `/admin` pages and cannot view, cancel or retry jobs. Admins keep access. Defense in depth: `ObanDashboardLive` re-checks admin on mount.
- **S2 — Telegram onboarding cannot bind a caller-chosen chat.** Lead `telegram-auth-six-digit-unthrottled-guess-binds-caller-chat_id`. Assumption (parent decision, no consumer exists in source: no page collects `chat_id`, the six-digit code is never shown to anyone): remove the public `GET /webhooks/telegram/auth` web fallback (route + controller + its tests/docs). Additionally, consuming one auth code for a patient invalidates that patient's other live codes (deep link and six-digit siblings), so a leftover code cannot rebind an onboarded patient. The bot `/start <token>` path keeps working.
- **S3 — Email identity is canonical.** Lead `alethea:accounts:email-identity-not-canonicalized-admin-admission`. Professional emails are trimmed and downcased before storage and lookup; uniqueness is case-insensitive at the DB level; registering `ADMIN@x` when `admin@x` exists fails with the unique-email error; login with any casing finds the same account. Email ownership verification is OUT of scope (follow-up).
- **S4 — No plaintext patient content in Oban args.** Lead `telegram_webhook_controller.ex:enqueue_message:plaintext-message-in-unpruned-oban-args`. Inbound Telegram message maps and outbound reply bodies are not stored as plaintext in `oban_jobs.args` (encrypt the sensitive payload with the existing vault, or pass a reference). Workers stay backward compatible with already-enqueued jobs in the old args shape. Configure `Oban.Plugins.Pruner` so completed/cancelled/discarded jobs are removed.
- **S5 — Clinical-record writes use the destroyable key.** Lead `clinical_record.ex:create_clinical_note+create_target_behavior+ai_proposal_worker:v1-patient-dek-defeats-crypto-erasure`. New ClinicalNote, TargetBehavior and AIProposal rows encrypt under the `patient_clinical_record` DEK and stamp `encryption_version: 2` (as the sibling paths do); reads keep decrypting v1 legacy rows; RAG chunks of new rows follow v2.
- **S6 — Entitlement requires a configured price.** Lead `alethea:billing:entitlement-ignores-configured-price-ids`. A subscription whose `price_id` is not in `PADDLE_PRICE_IDS` does not grant entitlement.
- **S7 — Voice transcription is bounded per patient.** Lead `alethea:transcription-queue:telegram-voice-no-per-patient-quota`. Telegram voice/audio transcription has a per-patient rate cap (configurable) and a file-size cap checked before download; a missing `duration` no longer bypasses the size bound. Patient-triggered voice jobs do not share the 2-slot queue with professional session transcriptions (own queue).

## Tasks

| ID | Specs | Route | Risk | Status | Commit |
|---|---|---|---|---|---|
| T1 | S1, S2 | delegated (writer A; parallel units) | item 2 (guards), item 3 (removes public route), item 4 (row locks) | done, verified | 49603bc |
| T2 | S3 | delegated (writer B) + parent (foundation email bridge) | item 1 (migration on stored data), item 2 | done, verified | 6f39a4b |
| T3 | S4, S7 | delegated (writer C) + parent (3 test files adapted to JobPayload) | item 1 (persisted job-args format), item 3 (args contract, queue) | done, verified | 0112b61 |
| T4 | S5 | delegated (writer D; parallel units) | item 1/2 (encryption of stored data) | done, verified | d7c957a |
| T5 | S6 | inline (≤100 lines) | item 2 (entitlement guard) | done, verified | fadf779 |

Route evidence: Writer trigger (a) — four independent units with disjoint edit surfaces, each several files; launched together. T5 is small and runs inline.

## Log

- L1 (2026-11-25, user): "revisar el repo con https://github.com/cloudflare/security-audit-skill"
- L2 (2026-11-25, user): "Arreglemos todo en un Work Tree separado"
- L3: Audit produced 7 needs_validation leads (no sandbox → none confirmed). Hardening notes are out of scope unless the user asks.
- L4: Decision for S2: delete the unused web fallback instead of hardening it (no consumer in source).
- L5: Baseline at c772941: `mix test` 3061 passed, 0 failures.
- L6: Writer B found foundation professionals bridged by exact email; parent made `professional_by_email/1` and `legacy_professional_for/1` canonical (RED 2 tests → GREEN). Writer C left 31 tests reading plaintext args in 3 files outside its surface; parent adapted them to `JobPayload`.
- L7: After all units: `MIX_TEST_PARTITION=E mix test` 3114 passed, 0 failures, 5 skipped; `MIX_ENV=test mix compile --warnings-as-errors` clean; `mix format --check-formatted` clean. Intermediate commits were not tested one by one.
- L8: Follow-ups out of scope: email ownership verification; dead-letter `text` column and `SessionTimeoutWorker` args still hold plaintext/raw chat_id; concurrent deep-link + six-digit consume race (only legacy queued jobs can redeem six-digit now); audit hardening notes; Spanish over-cap voice reply copy needs product review.
- L9: Independent verifier over c772941..HEAD: S1-S7 pass, no blockers. Its probes were added as regression tests and the voice cap query now uses the args GIN index (5cd0f2d). Full suite 3117 passed.
- L10 (2026-11-25, user): consent "Review this change" for the whole branch; native START stopped with `lens_context_budget_exceeded` (2833 lines). User chose "Revisar por commit".
- L11: Native RDD review per candidate, all granted by the user, all `approved` and acknowledged (authority burned): 6f39a4b (risk, resilience, reliability), 49603bc (risk, readability, reliability), 0112b61 (risk, resilience, reliability), d7c957a (risk, reliability), fadf779+5cd0f2d (risk, reliability).
- L12: Non-blocking advisories worth a follow-up: `Professional.changeset` raises on a nil email (normalize before validate_required); login lookups filter on bare `email` so the new `lower(email)` index is unused; foundation bridge should match on `legacy_professional_id` instead of `lower(trim(email))`; `edit_ai_proposal` on legacy v1 rows now re-encrypts edited text under the non-destroyable key; list reads can provision the clinical-record key; sibling-code revocation with SKIP LOCKED is best-effort and legacy six-digit onboarding jobs queued before deploy can still bind; voice cap window anchored at perform time; empty `PADDLE_PRICE_IDS` revokes every subscriber (check prod config before deploy).
- L13 (2026-11-25, user): "sí antes arreglá" (fix the L12 advisories before push/PR).
- L14: Follow-ups, inline, test-first (RED observed for each except the sandboxed concurrency test, where tasks share one connection; paired with an SQL-shape test): 01e0935 (nil email changeset, lower(email) lookup served by the index, foundation bridge by `legacy_professional_id` with exact-email fallback only for unlinked rows), c5948b1 (editing a v1 AI proposal re-keys the whole row to the CR DEK at v2; list reads load the CR key without creating it), 012748b (consume locks patient row, then code, then siblings with a plain update; onboarding worker drops `kind: six_digit` jobs), 1a8bcef (rekey_changeset always stamps v2; verifier probes as regression tests). Full suite 3130 passed; strict compile and format clean.
- L15: Independent verifier on 5c373da..HEAD: F1-F7 pass, no blockers; real-connection stress (40 rounds x 6 concurrent consume/invite/verify) found no deadlock. Native review, all granted by the user and approved, acknowledged: 01e0935 (risk, reliability), c5948b1 (risk, reliability), 012748b+1a8bcef (risk, resilience, reliability).
- L16: Remaining non-blocking suggestions (later work): test list reads for a patient with legacy v1 rows and no CR key; concurrency test should assert the winning chat hash; `code_query/2` could share `for_update_query/2`'s builder; per-patient voice cap window is anchored at perform time.
- Deploy checklist: duplicates query on `lower(trim(email))`; `PADDLE_PRICE_IDS` set and matching every active subscription. (Legacy `six_digit` onboarding jobs no longer need manual cancellation.)
- Next: push/PR are user decisions.
