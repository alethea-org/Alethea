# Tasks: Reply once after a Telegram message burst (#391)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1,670 (S1 ~300, S2 ~640, S3 ~730); treat as FLOOR — repo overrun precedent 12–97% → 1,900–3,300 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (S1) → PR 2 (S2) → PR 3 (S3) |
| Delivery strategy | auto-chain (3-PR chain pre-decided by orchestrator + design §Forecast) |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| S1 | Schema + read side, zero observable change | `feat/391-telegram-burst-reply` → `main` | `mix test test/alethea/clinical_test.exs test/alethea/telegram/journaling_reply_test.exs test/alethea/migrations/burst_coverage_test.exs` | Full existing `test/alethea/jobs/telegram_*` suite green UNCHANGED (proves behavior-preserving) | Revert PR; down-migration drops column/indexes, restores 5-state check |
| S2 | Burst worker (inert) + crisis supersession | `…-pr2` → S1 branch | `mix test test/alethea/jobs/telegram_burst_reply_worker_test.exs test/alethea/jobs/telegram_message_worker_test.exs` | `perform_job(TelegramBurstReplyWorker, …)` with `PhiWorkerMock`; crisis via `TelegramMessageWorker.perform/1` | Revert PR; no caller of `arm/1` on safe path, crisis supersede is no-op in sync mode (design File Changes row S2) |
| S3 | The switch: safe path arms, claim CASE, release, repair | `…-pr3` → S2 branch | `mix test test/alethea/jobs/` | `TelegramMessageWorker.perform/1` ×N → `perform_job(TelegramBurstReplyWorker)` → `TelegramOutboundWorker.perform/1`, `Client.Fake` sent-log | Revert PR → sync `generate/3` path returns; claim CASE + switch revert TOGETHER (hazard boundary) |

Hard rule: claim CASE (AD7) and safe-path switch MUST ship in the same PR (S3). Never re-split S3; trim lever = table-driving tests.
Live option (orchestrator's call mid-apply, not decided here): if S2 real diff > 600, split S2 into S2a (worker + primitives) → S2b (crisis supersession).

All code/SQL verbatim from design §Interfaces/Contracts. AD = design decision, R = spec requirement.

---

## S1 — `feat/391-telegram-burst-reply` (base `main`)

### Phase 1: Setup
- [x] 1.1 Create branch from fresh `main`; commit `openspec/sdd/reply-once-after-burst-391/{proposal,spec,design,tasks}.md` ALONE (`docs(sdd): plan #391 burst reply`) before any code. — done in a prior session (`758459d`).
- [x] 1.2 Baseline: `mix test test/alethea/jobs/ test/alethea/clinical_test.exs`; record pass count + `mix compile --warnings-as-errors --force` warning set. — 153 passed, 0 failures. Compile baseline: **1** pre-existing warning (`lib/alethea/clinical_record.ex:2411`, `validate_cited_evidence_ids/1` clause never used) — this differs from the 4-warnings-at-lines-1256/1377/1473/1549 claim given in the apply prompt; reported as a factual discrepancy, not fixed (file untouched, out of S1 scope).

### Phase 2: Migration + schema (R10, AD2)
- [x] 2.1 RED `test/alethea/migrations/burst_coverage_test.exs`: pre-existing inbound rows → self-covered, `list_burst_members == []` [R10]. Backfill SQL exposed as callable function, but on `Alethea.Clinical.BurstBackfill` (a `lib/` module), not the migration module — `priv/repo/migrations/*.exs` files are not loaded by `mix test`'s normal compile step, so a function on the migration module itself is unreachable from test code. The migration's `up/0` delegates to `BurstBackfill.sql/0` so the exact statement is shared, not duplicated.
- [x] 2.2 `mix ecto.gen.migration add_burst_coverage_to_messages` → `priv/repo/migrations/20261007185102_add_burst_coverage_to_messages.exs`: nullable `replied_by_message_id` → `messages` (`on_delete: :nothing`); partial index `(patient_id) WHERE direction='inbound' AND replied_by_message_id IS NULL`; index `(replied_by_message_id) WHERE NOT NULL`; check constraint + `'superseded'`; `up` backfill `SET replied_by_message_id=id WHERE direction='inbound'`; `down` restores 5-state check (`20261006040546…:30-34`).
- [x] 2.3 `lib/alethea/clinical/message.ex`: `belongs_to :replied_by_message` (binary_id via module's `@foreign_key_type` default, mirroring `reply_to_message`), NOT in `cast/2`.

### Phase 3: Read side (R8, R2, R9, AD8)
- [x] 3.1 RED `clinical_test.exs:101` extension: `superseded` + `sent` reply → only `sent` text in turns [R8].
- [x] 3.2 `clinical.ex` `turns_before/3`: `where: is_nil(m.delivery_state) or m.delivery_state != "superseded"`; typedoc adds `superseded`.
- [x] 3.3 RED `list_burst_members/1` (in `clinical_test.exs`, new describe block): ids "9","10","11" inserted out of order → order 9,10,11; self-covered excluded (covered by migration test); member covered by pending `elicited` reply included (absorb, AD5) [R2, R11].
- [x] 3.4 `clinical.ex`: `list_burst_members/1` per design members SQL, `ORDER BY telegram_message_id::bigint`, returns `{:ok, [{%Message{}, text}]} | {:error, term()}` (decrypting convention matched to `list_conversation_turns/3`/`build_patient_context/2`, since the design's bare-list pseudocode in `arm/1` is S2's sketch, not a literal spec for this function's error path).
- [x] 3.5 RED `test/alethea/telegram/journaling_reply_test.exs`: 3 members → `PhiWorkerMock` gets texts joined `"\n\n"` in order, each sanitized once, `message_id` = newest, history bounded at earliest member (no member in history) [R9].
- [x] 3.6 `journaling_reply.ex`: `generate_burst/2`; `generate/3` → `generate_burst(p, [{inbound, text}])`; guard/fallback use `List.last`. Guard/fallback/prompt untouched.

### Phase 4: Size + verify
- [x] 4.1 Trim lever applied BEFORE requesting any size exception: table-drove the 3.3 ordering case (one test, `for tg_id <- [...]` over 3 out-of-order ids) instead of 3 separate tests. `git diff --stat --cached origin/main` (full literal command, includes the already-committed SDD docs commit + an unrelated pre-existing untracked `.gga` file): 14 files changed, 1181 insertions(+), 4 deletions(-). **S1's actual code diff** (vs `HEAD`, excluding the prior docs commit and `.gga`): 8 files changed, 510 insertions(+), 4 deletions(-) = 514 changed lines. This exceeds the ~300-line floor forecast but sits inside the documented 12–97% overrun precedent band; no exception requested — the 3-PR chain was already the pre-decided delivery strategy for exactly this reason.
- [x] 4.2 Existing suite green unchanged (153/153, same as 1.2) + 7 new tests = 160/160 passed; zero new compile warnings (same single pre-existing one); `mix format --check-formatted` clean after `mix format`.

---

## S2 — `feat/391-telegram-burst-reply-pr2` (base S1 branch)

### Phase 5: Setup
- [ ] 5.1 Branch from S1 head. Re-verify design "Verified anchors" + File Changes line refs (`telegram_message_worker.ex:794-815, :367, :617-620`; `clinical.ex` shifted by S1); record deltas in tasks.md.

### Phase 6: Transaction primitives (AD5, AD6)
- [ ] 6.1 RED `clinical_test.exs`: cover only `IS NULL`/absorbed rows, returns count; absorb `pending→superseded` count; `uncovered_inbound?/1` true/false; self-covered never matched [R6, R11].
- [ ] 6.2 `clinical.ex`: `lock_patient_conversation!/1` (`SELECT … FROM patients WHERE id=$1 FOR UPDATE`), `supersede_absorbed/1`, `cover_members/3` (design cover SQL), `uncovered_inbound?/1`.

### Phase 7: Burst worker (AD1, AD3, AD4, AD9)
- [ ] 7.1 RED `test/alethea/jobs/telegram_burst_reply_worker_test.exs`: `arm/1` ×2 → one scheduled job, `scheduled_at` strictly later; arm while executing → new job [R1].
- [ ] 7.2 Create `lib/alethea/jobs/telegram_burst_reply_worker.ex`: EXACT AD1 `use Oban.Worker` (`keys: [:patient_id], period: :infinity, states: :scheduled`, `replace: [scheduled: [:scheduled_at]]`), `@window_seconds 45`, `arm/1`.
- [ ] 7.3 RED: 3 members → one reply, all `replied_by` set, anchor = max tg id, diagnosis + `:safe` outbound job (prio 9) inserted in-tx; `[]` → `:ok` no-op; patient mismatch → `:ok` [R2].
- [ ] 7.4 RED: save-time stale (Mock blocks on `:release`, insert inbound) → no reply/diagnosis/outbound, members uncovered, job re-armed [R3].
- [ ] 7.5 RED: pending R1 (A,B) + inbound C → R1 `superseded`, R2 covers A,B,C, Mock called once [R11].
- [ ] 7.6 `perform/1` per design save-tx sequence; `{:error, :stale | :coverage_lost | :reply_already_exists}` → `arm(args)`, `:ok`; generation error → raise.
- [ ] 7.7 RED concurrency: two overlapping jobs (`Task.async` + `:release`, idempotency `:227-248` precedent) → one reply, one outbound job [R6].

### Phase 8: Crisis supersession (R5)
- [ ] 8.1 RED `telegram_message_worker_test.exs`: uncovered A,B + pending ordinary reply + crisis C → reply `superseded`, A,B,C covered by crisis, Mock not called, crisis lane enqueued; later D → uncovered (new burst) [R5].
- [ ] 8.2 `telegram_message_worker.ex:794-815`: design crisis steps 1–6 after reply save; `arm/1` post-commit only if released > 0. `resume_reply` (`:367`) adds `"superseded"` terminal.

### Phase 9: Size + verify
- [ ] 9.1 Trim lever: table-drive 6.1 primitive cases + 7.3 edge cases (`[]`, mismatch). Then `git diff --stat <S1 branch>`; >600 → report split option to orchestrator.
- [ ] 9.2 Full `test/alethea/jobs/` green; no new warnings; format clean.

---

## S3 — `feat/391-telegram-burst-reply-pr3` (base S2 branch)

### Phase 10: Setup
- [ ] 10.1 Branch from S2 head. Re-verify anchors (`telegram_message_worker.ex:189-208, :226-331`; `clinical.ex:381-386, 477-485`; `telegram_outbound_worker.ex:138,142,273-290`) — S1/S2 shifted lines; record deltas.

### Phase 11: Dispatch claim-or-supersede (R4, AD7)
- [ ] 11.1 RED `telegram_outbound_worker_test.exs`: pending reply + newer uncovered inbound → no send (`Client.Fake` empty), `superseded`, members released, job armed; same with `_attempt: 2` [R4].
- [ ] 11.2 RED: dispatch claim racing burst absorb → exactly one winner [R6, R11].
- [ ] 11.3 `clinical.ex`: replace `:382` claim with ONE design CASE UPDATE; `claim_telegram_delivery/1` → `:claimed | :superseded | {:not_claimed, state}`; release `SET replied_by=NULL WHERE replied_by=R` same tx.
- [ ] 11.4 `telegram_outbound_worker.ex` `begin_journaling_delivery/1`: `:superseded` → `arm/1` + `{:skip, "superseded"}`; Pacer order unchanged.

### Phase 12: Safe-path switch (R1, R7)
- [ ] 12.1 RED `telegram_message_worker_test.exs`: two ordinary inbound → one scheduled burst job, no reply row; `:ai_analysis` job per inbound [R1, R7].
- [ ] 12.2 `telegram_message_worker.ex`: safe branch → `TelegramBurstReplyWorker.arm/1`; delete `handle_safe_path`/`persist_and_enqueue_outbound` (`:226-331`).
- [ ] 12.3 `mix ecto.gen.migration repair_burst_coverage`: NULL inbound → `COALESCE(reply.id, id)`; RED/GREEN in `burst_coverage_test.exs` [R10].

### Phase 13: Rewrite sync-reply tests
- [ ] 13.1 `telegram_message_worker_idempotency_test.exs`: 7 Mock sites → drive `perform_job(TelegramBurstReplyWorker)`.
- [ ] 13.2 `telegram_message_worker_guardrails_test.exs`: 5 sites, table-driven.
- [ ] 13.3 `telegram_message_worker_test.exs`: 14 sites.
- [ ] 13.4 `telegram_message_worker_reminder_test.exs`: 1 site.
- [ ] 13.5 E2E: 3 inbound out of order → burst → outbound sends once [R2]; existing sentiment regression test passes.

### Phase 14: Size + verify
- [ ] 14.1 Trim lever: table-drive 13.x rewrites + 11.1 attempt variants. NEVER re-split S3. Then `git diff --stat <S2 branch>`.
- [ ] 14.2 `mix precommit` green; no new warnings.
