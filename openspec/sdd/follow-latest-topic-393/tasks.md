# Tasks: Follow the latest topic and close exploration gently (#393)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1060 (realistic 1600-2300, #391 overran 71-124%) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | S1 → S2 → S3 → S4 |
| Delivery strategy | ask-on-risk (not passed; default) |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Branch (base) | Focused test command | Runtime harness | Rollback boundary |
|------|---------------|----------------------|-----------------|-------------------|
| S1 data | `feat/393-follow-latest-topic` (main) | `mix test test/alethea/clinical/exploration_state_test.exs` | `mix ecto.migrate && mix ecto.rollback` | migration + `message.ex` + `clinical.ex` read/6th arg; no callers |
| S2 rules | `-pr2` (S1) | `mix test test/alethea/telegram/topic_exploration_test.exs test/alethea/telegram/journaling_fallback_test.exs` | N/A: inert pure module | `topic_exploration.ex` + fallback lists |
| S3 wiring | `-pr3` (S2) | `mix test test/alethea/jobs/telegram_topic_exploration_test.exs` | worker-entry test via `perform/1` + `run_burst_reply/0` | `journaling_reply.ex`, burst worker, behaviour/chain/phi_worker key |
| S4 prompt | `-pr4` (S3) | `mix test test/alethea/ai/journaling_prompt_test.exs test/alethea/jobs/` | full worker-entry suite | `journaling_prompt.ex` + its tests |

Per-slice trim lever (apply BEFORE requesting size exception): table-drive repetitive cases via `for {name, input, expected} <- [...]` loops; share seed helpers.

## Phase 1: S1 Data layer (Stretch State, Retry Stability, Storage Contract)

- [x] 1.1 Create branch `feat/393-follow-latest-topic` from main; commit `openspec/sdd/follow-latest-topic-393/*.md` (`docs:`) before code.
- [x] 1.2 `mix ecto.gen.migration add_exploration_state_to_messages`; add 2 nullable columns + `messages_exploration_questions_check` (design §2 SQL); verify rollback.
- [x] 1.3 `message.ex`: add `exploration_questions :integer`, `closing_invitation_sent :boolean`, comment block; never cast.
- [x] 1.4 RED `test/alethea/clinical/exploration_state_test.exs`: none, crisis reset, session reset, nil session, legacy nil, superseded skipped, failed/ambiguous counted, bounded at earliest, stored values.
- [x] 1.5 GREEN `clinical.ex`: extract `before_snapshot/3` from `turns_before/3` (no behavior change); add `exploration_state/3` (newest outbound, `limit 1`, no decrypt).
- [x] 1.6 RED+GREEN `save_telegram_reply/6` `exploration \\ nil` → `put_change` both columns; nil writes NULL.
- [x] 1.7 Trim lever: table-drive 1.4 reset rows; `mix precommit`; diff ≤400 else exception note.

**S1 status (2026-10-09): all 7 tasks done.** Focused + regression suites green (318 tests across `exploration_state_test.exs` + `clinical_test.exs` + every caller of `save_telegram_reply`/`save_message`/`Message` schema), `mix compile --warnings-as-errors` clean (own app, 198 files; pre-existing dep warnings in bandit/phoenix/cloak_ecto and one pre-existing `outbox_test.exs` type warning — verified unrelated by reproducing on stashed main), `mix format --check-formatted` clean. Migration rollback verified. Diff vs `origin/main` for S1's own code (excluding the already-committed SDD docs and the pre-existing untracked `.gga`): `clinical.ex` +105/-5, `message.ex` +10, migration +33, `exploration_state_test.exs` +204 ≈ 352 lines, under the 400-line budget — no `size:exception` needed. Inert: no production caller invokes `exploration_state/3` or passes a 6th argument to `save_telegram_reply/6` yet.

## Phase 2: S2 Pure rules + fallback (Marker Signal, Question Limit, Post-Closing)

- [x] 2.1 Branch `-pr2` from S1; re-verify design anchors (`clinical.ex`, `journaling_fallback.ex`) vs branch state.
- [x] 2.2 `journaling_prompt.ex`: add `@new_marker`/`@same_marker` + `markers/0` only (no prompt text change).
- [x] 2.3 RED `journaling_fallback_test.exs`: closing/ack copy passes `JournalingOutputGuard`, no `?`/`¿`; `variants/0` still 4.
- [x] 2.4 GREEN `@closing_invitations`, `@acknowledgements`, `closing_for_inbound/1`, `acknowledgement_for_inbound/1` (`:erlang.phash2`).
- [x] 2.5 RED `topic_exploration_test.exs`: `parse_marker/1` cases (leading, same-line, own-line, lowercase, spaced, misplaced, malformed, unclosed, missing, marker-only "").
- [x] 2.6 GREEN `lib/alethea/telegram/topic_exploration.ex` `parse_marker/1` per design §1 regexes.
- [x] 2.7 RED `mode/1` + `enforce/4` table (design §3 four rows, `model_version` swap, `:exploration` map); GREEN implement.
- [x] 2.8 Trim lever: table-drive 2.5/2.7; `mix precommit`.

**S2 status (2026-10-09): all 8 tasks done.** Focused suites green: `topic_exploration_test.exs` (22), `journaling_fallback_test.exs` (10), `journaling_prompt_test.exs` (16) — 48 total. Broader regression (`test/alethea/telegram/ test/alethea/ai/journaling_prompt_test.exs test/alethea/ai/journaling_output_guard_test.exs test/alethea/jobs/`) → 400 passed, 0 failures — confirms zero observable behavior change (nothing in production code calls `TopicExploration` or the new fallback/marker functions yet). `mix compile --warnings-as-errors` clean. `mix format --check-formatted` clean. Diff vs `feat/393-follow-latest-topic` (S1's branch) for S2's own code (excluding the pre-existing untracked `.gga`): 6 files, +435/-0 — ~35 lines (~9%) over the 400-line guard after the table-drive trim lever was applied; flagged to the orchestrator rather than self-granted as `size:exception`. Not committed — left staged-free in the working tree for the orchestrator.

## Phase 3: S3 Wiring (Marker Signal, Request Contract, Limit)

- [x] 3.1 Branch `-pr3` from S2; re-verify anchors in `journaling_reply.ex`, burst worker, chain, phi_worker.
- [x] 3.2 Behaviour/`PhiWorker`/chain `run/1`: `exploration_mode` via `Map.get(params, :exploration_mode, :open)`; existing tests untouched.
- [x] 3.3 RED `test/alethea/jobs/telegram_topic_exploration_test.exs`: marker stripped (row, job body, `ai_diagnoses.ai_response`), count 0→1, 2→3, missing marker counts, closing at 3, ack post-closing, guard fallback counts/closes, `:closing` in payload, `EmotionAnalysisWorker` enqueued.
- [x] 3.4 GREEN `generate_burst/2`: state → mode → request key → `parse_marker` before `guard/2` (`""` → `:empty_response`) → `enforce/4`.
- [x] 3.5 GREEN burst worker: pass `chain_result.exploration` to `save_telegram_reply/6`; crisis caller unchanged.
- [x] 3.6 Update `telegram_message_worker_guardrails_test.exs` key list to 4 keys.
- [x] 3.7 Trim lever: table-drive 3.3 count rows; if >400, split 3.3 into S3a/S3b before exception.

**S3 status (2026-10-09): all 7 tasks done.** Diff vs `feat/393-follow-latest-topic-pr2` (S2's branch): 8 files, +382/-17 = 399 lines — under the 400-line budget, no `size:exception` needed (trim lever already applied: the 3.3 test file is one 5-row table-driven `describe` plus 3 standalone tests, instead of ~8 near-duplicate tests). One unanticipated deviation: `design.md` cited only `telegram_message_worker_guardrails_test.exs:132` for the request-key-count update, but `test/alethea/jobs/telegram_message_worker_running_summary_test.exs` had the same literal 3-key assertion in 3 more places (not cited by design) — updated to the 4-key contract there too; confirmed via `rg` that no other test file carries this assertion. Full repo-wide search for the exact 3-key literal left zero other occurrences.

## Phase 4: S4 Prompt + reset tests (Multi-Topic, Stretch resets) — HARD GATE

- [x] 4.1 BLOCKER: confirm `parse_marker` stripping is live on `-pr3` and S3 merged into chain before S4 merges; S4 never reaches main ahead of S3.
- [x] 4.2 Branch `-pr4` from S3; re-verify `journaling_prompt.ex` anchors.
- [x] 4.3 RED `journaling_prompt_test.exs`: `system_prompt(:open|:closing)`, new headings, closing section only in `:closing`, examples render `Alethea: <<MARKER>> text`, `:follow_up`, `:multi_topic`.
- [x] 4.4 GREEN prompt: sections, two `@` variants, `system_prompt/0` → `:open`.
- [x] 4.5 RED+GREEN worker-entry: NUEVO resets after closing, crisis reset, session reset, truncated NUEVO, multi-member NUEVO burst, retry after rollback same mode.
- [x] 4.6 E2E: drive all spec scenarios (= #393 ACs) via `perform/1` + burst job; no live model.
- [ ] 4.7 Trim lever; `mix precommit`; land chain to main once.

**S4 status (2026-10-09, resumed after a mid-task crash — see apply-progress for full detail):** 4.1-4.6 done. 4.3-4.6 were already complete and passing in the uncommitted working tree when this session started (verified, not rewritten): `journaling_prompt.ex`'s two `system_prompt/1` variants, `markers/0`, the `:follow_up`/`:multi_topic` examples, and `journaling_prompt_test.exs`'s full heading/closing/marker-protocol coverage (26/26 passed); `chains/guided_conversation_chain.ex` and `phi_worker.ex` wiring `exploration_mode` into `system_prompt/1` selection (closes the S3→S4 handoff seam); and — contrary to the crashed agent's own last-known status — `test/alethea/jobs/telegram_topic_exploration_test.exs` ALREADY contained the full S4 worker-entry + E2E suite (NUEVO-after-closing reset, crisis reset, session reset, truncated-NUEVO, multi-member NUEVO burst, retry-after-rollback, plus all of S3's original scenarios), 14/14 passed, matching design's own "Testing Strategy" table which names this one file (not a separate e2e file) as the worker-entry/E2E layer for every spec.md scenario. 4.1 confirmed by reading `journaling_reply.ex`: `parse_marker`/`enforce` wiring from S3 is present and unreverted on this branch. 4.2 confirmed: branch `feat/393-follow-latest-topic-pr4` checked out from `-pr3`. 4.7's trim lever was already applied (the 5-row `for` table from 3.7, reused for the count-progression cases); `mix precommit`'s full suite run and "land chain to main once" are intentionally left to the orchestrator per this session's explicit instructions (no full-suite run, no commit, S4 must not merge ahead of S1-S3 confirmed live) — 4.7 left unchecked for that reason.
