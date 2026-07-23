# Exploration — session-timeout-channel-neutral (#86)

**Source issue:** alethea-org/Alethea#86 — "Telegram session close: persist summary + channel-neutral goodbye"
**Artifact store:** hybrid (mirrored to Engram `sdd/session-timeout-channel-neutral/explore`)
**Strict TDD:** active — `mix test`. Base: main (contains #84 + #85).
**Two goals:** (1) channel-neutral SessionTimeoutWorker + Telegram auto-close enqueue; (2) crisis-path atomicity fix.

## Current state

### Session lifecycle — lib/alethea/clinical/session_manager.ex
- `current_open_session/1` (12-43): `Repo.transaction` + `pg_advisory_xact_lock(phash2(patient_id))`, selects `status=="open"` or creates. Lock is txn-scoped. NO staleness/age check.
- `close_session/1` (61-68): plain `Repo.update` → `closed_at` + `status:"closed"`.
- `Session` schema (lib/alethea/clinical/session.ex): `started_at`, `closed_at`, `status`, `belongs_to :patient` (LEGACY `Alethea.Accounts.Patient`). **NO channel/phone/chat metadata field.** Migration confirms exactly these columns — nothing to "reuse" for channel.

### WhatsApp worker to generalize — lib/alethea_jobs/session_timeout_worker.ex (91 lines)
- `perform/1` args: `%{"session_id","patient_id","phone"}` — `phone` hardcoded/required.
- `run_close_flow/3`: idempotent (skip if already closed) → `close_session` → `list_session_messages` → decrypt → sanitize → `roberta_worker().analyze_batch` → `save_trends` → `session_summary_chain().run` → `save_summary` → **`whatsapp_client().send_message(phone, @goodbye_message)`**. The summary/trends pipeline is ALREADY channel-independent — ONLY the final send line is WhatsApp-coupled.
- Scheduled by process_message_worker.ex:218-226 `schedule_session_timeout/3`, called from BOTH safe (114) and crisis (178) branches AFTER inbound save. Oban `unique:[fields:[:args], period:40*60]` + `insert!(replace:[:scheduled_at])` — renewal = each message upserts on identical `%{session_id,patient_id,phone}` args, pushing `scheduled_at` back.
- Tests that MUST stay green: test/alethea_jobs/session_timeout_worker_test.exs — 2 tests call `perform_job(SessionTimeoutWorker, %{session_id:,patient_id:,phone:})` with NO `channel` key. Generalized worker must accept this exact shape as the WhatsApp default.

### Telegram identity split (decisive for channel dispatch)
- Two Patient schemas: `Alethea.Accounts.Patient` (legacy, `whatsapp_number_hash`) and `Alethea.Foundation.Accounts.Patient` (`foundation_patients`, `telegram_chat_id_hash`, `belongs_to :legacy_patient`). `Session.patient_id` FKs to the LEGACY table only; foundation (which knows Telegram) is not reachable from a Session row without an extra lookup, and NO reverse lookup (legacy→foundation) exists today.
- **Raw Telegram `chat_id` is NEVER persisted at rest** — only `telegram_chat_id_hash` (one-way HMAC). Raw `chat_id` exists transiently only in Oban job args (already the pattern for TelegramOutboundWorker, telegram_outbound_worker.ex:41-48 "Why chat_id is in the args (PHI surface)"). DECISIVE: a design reconstructing the goodbye send from persisted state alone CANNOT recover the raw chat_id — it must be captured at enqueue time.

### telegram_message_worker.ex
- `process_bound_message/5` (111-181): inbound persisted 136-151 via `save_telegram_message/6`; `enqueue_emotion_analysis` at 153; branches to `handle_safe_path/7` or `handle_crisis_path/9` at 155-179. NO timeout scheduling exists here (deferred from #85; test :446-458 asserts `refute_enqueued(SessionTimeoutWorker)`).
  → Goal 1 enqueue insertion point: right after line 151 (successful inbound save), before/alongside 153 — ONE call site covers both branches (unlike WhatsApp which duplicates per-branch).
- `handle_crisis_path/9` (507-598) sequence: (1) `Accounts.update_patient(urgent_intervention: true)` bare-match 521-522; (2) `save_ai_diagnosis` bare-match 525-530; (3) `PubSub.broadcast(:crisis_detected, "psychologist:alerts")` 540-551; (4) crisis outbound `save_telegram_message` with safe case/raise 563-578 (this is what 7bb409d fixed for PHI-leak — NOT atomicity); (5) `enqueue_outbound(lane: :crisis)` 587-590.
  → Goal 2: wrap (1)+(2)+(4) in ONE `Repo.transaction`; move (3) broadcast + (5) enqueue to strictly AFTER commit. NOTE this REORDERS broadcast (today fires BEFORE outbound save) — required by Goal 2 framing, closes R1-W4. Mirrors the safe-path fix already at persist_and_enqueue_outbound (250-267, documented Round-2 SEVERE fix).
- Stale `@moduledoc` (51-59) still claims crisis raises NotImplementedError — false since #85 (optional fix).

### 7bb409d ("prevent changeset leak on crisis outbound persistence failure")
Already fixed the crisis outbound PHI-leak (error-message shape) — atomicity was explicitly NOT addressed. So Goal 2 (atomicity) is genuinely still open.

## R1 WARNINGs mapping

- **R1-W1 (staleness race)**: latent for Telegram today only because nothing closes a Telegram session except explicit test `close_session/1`. Once Goal 1's worker fires on schedule, the race is structurally LIVE: `current_open_session/1` returns S (134) → inbound save (136-151) is a separate later write, no lock held across the gap → if a previously-scheduled timeout for S fires and closes S in that gap, inbound commits with `session_id=S` where `S.status="closed"`. NOT new to #86 — identical gap exists in WhatsApp's ProcessMessageWorker since before #85, same fetch-then-save-then-reschedule pattern, accepted risk. Blast radius if it fires: one late message attaches to an already-closed/summarized session (silently excluded from that summary; next message starts fresh) — no crash, no corruption, minor continuity gap. Per fixed decision (don't touch current_open_session), recommend DOCUMENT as accepted/deferred risk, not fix.
- **R1-W3 (no-timeout coverage)**: #85's no-auto-close test (:446-458) only covers safe path. #86 adds the worker AND must cover crisis-path enqueue + session-age behavior. Test :446-458 must be REPLACED (it asserts the opposite of Goal 1's required behavior), not preserved.
- **R1-W4 (crisis non-atomic)**: Goal 2.

## R3 SUSPECT — crisis outbound failure-mode coverage (EXPLICIT #86 requirement)
- Safe path has a full failure suite (465-639): dup-inbound, LLM-unavailable, empty-response, diagnosis-save-failure with atomicity proof (`outbound_count==0` at 606), PHI-non-leak (636).
- Crisis branch (647-883+, 9 tests) has NONE that force a persistence failure — all happy-path. #85 verify-report (05-verify-report.md:177, WARNING 3) explicitly named this and routed it to #86. #86 must add a crisis test mirroring the safe pattern: force a save failure on one transacted step, assert (a) no partial commit, (b) no PHI leak in raised error, (c) PubSub broadcast did NOT fire (now post-commit-only).

## Channel-dispatch mechanism — the NEW decision

Fixed list framed this as "session-row metadata vs new column." Investigation: session-row channel metadata DOES NOT EXIST today, and neither a column nor a reverse-lookup can supply the raw Telegram `chat_id` (never stored at rest). So a THIRD option is the only viable one:

1. **New `channel` column on clinical_sessions** — durable, queryable, BUT needs a migration + threading `channel` into current_open_session/open_session (shared, inside advisory-lock txn — the exact thing the fixed decision says to touch minimally); AND still can't carry the raw chat_id needed for the send. Medium-High.
2. **Reverse-lookup patient channel at fire time** — no reverse-lookup fn exists; still can't recover raw chat_id (only hash stored) → send undeliverable; dual-bound patient ambiguity. STRUCTURALLY BLOCKED.
3. **[RECOMMENDED] Thread `channel` + routing identifiers through Oban job args at enqueue time** — no schema/migration/SessionManager touch. Caller already holds what it needs: ProcessMessageWorker has `phone` at both call sites; TelegramMessageWorker.process_bound_message has `chat_id`+`chat_id_hash` at the exact enqueue point. Same pattern already used+documented for TelegramOutboundWorker (raw chat_id in args). Oban persists args durably (oban_jobs.args) — no less durable than a column for the worker's purpose. Reuses existing `unique:[fields:[:args]] + replace:[:scheduled_at]` renewal. WhatsApp shape (`%{session_id,patient_id,phone}`, no channel key) stays valid by defaulting absent channel → "whatsapp" when phone present (matches current tests exactly). Low-Medium.

**Recommendation: Approach 3.** Only option that supplies the raw chat_id the send needs, no migration, no SessionManager/Session touch, WhatsApp tests unmodified.

## Affected areas
- lib/alethea_jobs/session_timeout_worker.ex — generalize: channel-aware goodbye send + channel-aware args (~90→~150).
- lib/alethea_jobs/process_message_worker.ex:218-226 — schedule_session_timeout call sites (114,178) keep working unmodified (backward-compat args) (~5-10 lines).
- lib/alethea/jobs/telegram_message_worker.ex — new enqueue after line 151; handle_crisis_path/9 (507-598) transaction wrap; optional moduledoc (~60-80 changed).
- lib/alethea/clinical/session_manager.ex — expected NO change (flag if design finds it unavoidable).
- test/alethea_jobs/session_timeout_worker_test.exs — must stay green unmodified.
- test/alethea/jobs/telegram_message_worker_test.exs:446-458 — must be REPLACED, not preserved.
- New/updated tests for generalized worker (Telegram goodbye path, channel dispatch) + R3 crisis-outbound-failure (~250-400 lines).

## Size / PR split
Combined estimate ~450-650 changed lines → likely EXCEEDS the 400 review budget. sdd-tasks should plan a chained/stacked split: **PR-1 = Goal 1** (channel-neutral worker + Telegram enqueue); **PR-2 = Goal 2** (crisis atomicity + R3 test).

## Decisions to confirm before propose
1. **Channel dispatch = Approach 3 (Oban job args)** — deviates from the fixed list's "metadata vs column" framing (metadata doesn't exist; column can't carry raw chat_id). Needs sign-off.
2. **R1-W1 disposition** — accept/document as deferred risk (mirrors WhatsApp's accepted risk; fixing needs current_open_session/locking changes the fixed decisions discourage) vs fix in #86.

## Risks
- R1-W1 live-but-pre-existing (see above).
- Broadcast reorder to post-commit is a visible sequencing change — document so reviewers don't read as scope creep.
- Test :446-458 asserts the opposite of Goal 1 — replace, don't preserve.
- Size likely >400 → chained PRs.
- Dual-bound patient (WhatsApp+Telegram) edge case — Approach 3 sidesteps it (channel captured per message arrival), design-phase note.

**Ready for proposal:** yes, after the 2 decisions are confirmed.
