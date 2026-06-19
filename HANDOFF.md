# Session Handoff — `telegram-paciente-foundation` chain

> **Audience:** the next session, when the user returns to continue
> the `telegram-paciente-foundation` change after a long break.
> This doc captures the **decisions, preflight, and current state** that
> the previous session established so the next one doesn't have to
> re-derive them from the conversation.

## Chain state (as of last session)

```
main  (4d6e8cf — PR #1a merge #72)
  └─ pr-1a-foundations-a  (47c94d6d — PR #1b clean merge #73)
       └─ pr-1b-foundations-b  (7470de8 — PR #2 #75 merge, end of PR #2)
            └─ (PR #3a — clinical safe path — NEXT, not yet started)
```

PRs already merged to the chain:
- ✅ **PR #1a** (#72) — sealed secrets + HMAC helper + BotConfig + BotToken
- ✅ **PR #1b** (#73) — Pacer + DeepLinkToken + ADR-0008 (clean slice, 8 commits)
- ✅ **PR #1b-fixes** (#74) — F-04..F-16 follow-up batch + chore (12 commits, split from PR #1b to keep each PR under the soft budget)
- ✅ **PR #2** (#75) — webhook entrypoint + Oban enqueue + Pacer supervision + **W-1 cleanup** (8 tasks, 9 commits)

Still to land:
- ⏳ **PR #3a** — clinical safe path: TelegramMessageWorker body + TelegramOutboundWorker with Pacer + 429 + dead-letter + Telegram.Client.Req production adapter + TelegramDeadLetter schema + migration
- ⏳ **PR #3b** — clinical crisis branch: `:crisis_detected` PubSub + `telegram_outbound_crisis` priority lane + queue-full escalation + `ops:alerts` broadcast
- ⏳ **PR #4** — onboarding: PatientAuthCode + DeepLink + 6-digit routes + TelegramOnboardingWorker body + welcome emission

Per chain strategy `feature-branch-chain` (locked, see `tasks.md` §"Re-Slice Justification"). Only the tracker (`feat/telegram-paciente-foundation`, draft, no-merge) eventually lands to `main`.

## W-1 status (from PR #1b verify report WARNING #1)

**RESOLVED** in PR #2 (commit `0b1b4de`, TASK-2-6). The Pacer has a `handle_info(:cleanup, _)` callback that drops per-chat ETS rows whose `last_refill_ms` is older than `:idle_threshold_ms` (default 1 h) every `:cleanup_interval_ms` (default 5 min). Cleanup runs in a separate `handle_info` callback — does NOT touch the `acquire/1` call path (verify report invariant). Global table is a singleton — never accumulates, never touched. 3 tests in `test/alethea/telegram/pacer_test.exs` cover the acceptance criteria.

## SDD Session Preflight (cached for the chain)

The orchestrator's `sdd-*` commands require a session preflight. The previous session cached these values:

- **Pace:** `A1` (Interactive — show each phase + wait for confirmation before continuing)
- **Artifacts:** `B1` (OpenSpec — files in the repo, traceable in review)
- **PRs:** `C3` (Chained — split into chained PRs from the start, per the existing chain strategy)
- **Review:** `D2` (800 lines — soft budget, already documented in `tasks.md` §"Re-Slice Justification")

If the next session needs to re-establish this, the user's previous choices were "usar recomendado" (use recommended). The four canonical values above are the result.

## Decisions established (read these before re-litigating)

These decisions are **locked**. Do not re-litigate them in a new session; if the user asks to revisit one, surface this handoff first so they remember the context.

### 1. PR #1b was split into two PRs (user chose option 2 when given the choice)

The original PR #1b accumulated 20 commits (~2000 insertions) and exceeded the soft 800-line review budget by ~2.5×. The user chose to split it into:
- **PR #1b** (clean slice) — 8 commits, 1126 insertions: TASK-1b-1, TASK-1b-2, TASK-1b-3, test cleanup, defensive test trim, apply-progress docs, W-2 fix, W-2 docs
- **PR #1b-fixes** (F-XX follow-up batch) — 12 commits, 903 insertions: F-01..F-16 + chore

The split was a `git reset --hard` + `git cherry-pick` operation. The PR #1b branch's commits are byte-identical to their pre-split state. The PR #1b-fixes branch was created with `git checkout -b pr-1b-fixes` from PR #1b's tip at the time of the split (`b0cca53`), then `cherry-pick -x` of the 12 F-XX commits in chronological order.

The **chore** (`ce7225b` → `19eb4d4` on pr-1b-fixes) lives on **PR #1b-fixes**, NOT PR #1b. The chore's diff touches `Pacer.inspect_per_chat/0` (F-12) and `Pacer.validate_positive!/2` (F-09) — functions that don't exist on the pre-F-XX PR #1b branch. Putting the chore on PR #1b would have failed to apply cleanly.

### 2. PR #2 was opened as a single PR with a documented 2.5× overshoot (user chose option 3 when given the choice)

PR #2 ended up at 2037 insertions / 25 files — 2.5× the soft budget. The user chose to open it as a single PR (option 3) rather than split it (option 2) because the 8 tasks are a single cohesive unit:

- The 8 tasks are atomic around the wire (controller without workers won't compile; router without plug is a 401-on-everything route).
- The W-1 cleanup (TASK-2-6) is coupled to the Pacer supervision (TASK-2-6) — splitting them would create a half-state where the supervisor exists but the periodic cleanup doesn't.
- Strict TDD is a per-task discipline, not a per-PR one; splitting tasks across PRs violates the RED-GREEN-REFACTOR cycle.
- Tests are 42% of the diff (~860/2037) — the strict-TDD invariant of 1.1–1.3× test:impl ratio.

The PR #75 body documents the overshoot in a dedicated section. The 10 test-side deviations are all Oban 2.x / Phoenix 1.8.7 / Elixir 1.18 API fixes — none change production logic.

**Future implication:** when the user is given the "split vs. document-overshoot" choice, they tend to choose **document-overshoot for cohesive units** and **split for clear unit boundaries** (e.g. when the work is genuinely follow-up fixes that landed in the same PR by accident).

### 3. The sdd sub-agent (orchestrator's `sdd-apply`) is unreliable in this OpenCode environment

The `sdd-apply` sub-agent cancelled mid-task on multiple occasions. The cancellation pattern: the sub-agent writes the test file and worker stubs successfully, but the tool reports "Task cancelled" before the sub-agent can commit. State was recovered manually:

- The sub-agent's work was on disk (test files, worker modules, config changes)
- The orchestrator inspected the state and wrote the missing controller
- Fixed 3 bugs the sub-agent had left: `Phoenix.ConnTest.dispatch/4` → `dispatch/5` with `:post`, `Oban.Testing.assert_enqueued/1` → arity-2 with explicit `Alethea.Repo`, worker column filter removed the `Elixir.` prefix

**Implication for the next session:** for PR #3a, prefer to **work inline** rather than delegating to the sdd-apply sub-agent. The sub-agent's tool-cancellation issue is environmental, not a code issue. If the sub-agent is used and reports "cancelled", the orchestrator must inspect `git status` + `git diff` to see what was actually written before retrying.

### 4. The apply-progress.md was lost during branch checkout and reconstructed

The original 433-line PR #1b apply-progress.md (untracked on `pr-1b-foundations-b` working tree) was overwritten when the orchestrator checked out a new `sdd/telegram-paciente-foundation` branch from `origin/main`. The file content is unrecoverable from git (it was never committed). The 106-line PR #1a content survived (it was tracked on `main`).

The reconstructed version is on the `sdd/telegram-paciente-foundation` branch (commit `bf747b1`) and combines:
- The PR #1a content (preserved verbatim from `main`)
- A new "PR #1b" section that references the verify report for TDD evidence (the prose is condensed but the structure is preserved)
- A new "PR #1b-fixes" section that documents the 12 F-XX commits + chore + SHA mapping table
- A new "PR #2" section that documents the 8 tasks + 10 deviations + W-1 resolution
- The PR #1b / PR #1b-fixes split is documented in the "post-apply refactor" section of the PR #1b apply-progress

The next session should NOT try to recover the original 433-line content — it doesn't exist. The reconstructed version is the source of truth going forward.

### 5. The `sdd/telegram-paciente-foundation` branch is the SDD artifacts home

Created from `origin/main` and pushed. Contains the change's documentation (proposal, design, tasks, specs, apply-progress, verify reports) on a branch SEPARATE from the code chain. This branch is **not** in the chain topology — it's a documentation overlay.

When a new session starts work on PR #3a, the orchestrator should:
1. Check out `sdd/telegram-paciente-foundation` to read the artifacts
2. Check out `pr-1b-foundations-b` to base PR #3a off of
3. Create `pr-3a-clinical-safe` from `pr-1b-foundations-b`
4. Implement the 4 tasks from `tasks.md` §"PR #3a"
5. Push + open PR against `pr-1b-foundations-b`

The sdd branch does NOT need to be re-merged into the chain — it's a parallel doc branch.

## PR #3a — the next slice

**Title:** `feat(telegram): clinical round-trip safe path with outbound pacer and dead letter`
**Base branch:** `pr-1b-foundations-b` (the chain tip after PR #2 merged)
**Head branch (to create):** `feat/telegram-paciente-foundation/pr-3a-clinical-safe`
**Estimated lines:** 740 (within 800 soft budget; per `tasks.md` §"PR #3a totals")
**Estimated time:** 1.5–2 hours with strict TDD and a fresh head

The 4 tasks:

| ID | Title | Est. lines | Notes |
|---|---|---|---|
| TASK-3a-1 | `TelegramMessageWorker` full body: idempotency + patient resolution + safe clinical round-trip (persist inbound via `Clinical.save_message/7`, enqueue `EmotionAnalysisWorker`, call `CrisisMonitor.detect/1` (stubbed to `:safe`), call `Alethea.AI.llm().chat/2`, persist outbound, enqueue `TelegramOutboundWorker`) | 150 impl + 200 test = 350 | **Largest single task in the chain.** Requires the Fakes for `Alethea.AI.llm()` and `EmotionAnalysisWorker` from `config/test.exs` (already wired). `CrisisMonitor.detect/1` is stubbed to return `:safe` in this PR; the `:crisis` branch lands in PR #3b. |
| TASK-3a-2 | `TelegramOutboundWorker`: `Pacer.acquire(chat_id_hash)` + `Client.send_message(chat_id, text)` + 429 retry with jittered exponential backoff + dead-letter on exhaustion. Also `TelegramDeadLetter` schema + `foundation_outbound_dead_letters` migration. | 100 impl + 150 test = 250 (impl includes the schema + migration) | Crisis-bypass `perform_now/1` is out of scope (PR #3b). |
| TASK-3a-3 | `TelegramDeadLetter` schema + `foundation_outbound_dead_letters` migration. | 30 impl + 15 migration + 35 test = 80 | **(Already counted in TASK-3a-2 above.** Originally a separate task in `tasks.md` but the work is naturally part of the outbound worker. May split if needed for review.) |
| TASK-3a-4 | `Telegram.Client.Req` production adapter. Uses `Req` to POST to `https://api.telegram.org/bot<token>/sendMessage`. Tests with `Bypass` (the project already has `Req.Test` configured for some tests). | 30 impl + 30 test = 60 | Wired in `config/config.exs` as `config :alethea, :telegram_client, Alethea.Telegram.Client.Req` (the `:test` and `:dev` configs stay on the Fake). |

**Important constants for PR #3a** (from `tasks.md` §"PR #3a — Composition"):

- `update_id` dedup state: 24 h Oban unique on `telegram_update_id` — **already in place** from PR #1b's `TelegramMessageWorker` stub. PR #3a widens the worker body but the unique config stays.
- `telegram_outbound` queue: 10 (default), already registered in `config/config.exs` from PR #2's TASK-2-6.
- `telegram_outbound_crisis` queue: 10 (default), already registered. PR #3a does NOT consume it (PR #3b does).
- Patient lookup: `Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1` (already in place from PR #2's TASK-2-1).
- ChatIdHash: `Alethea.Telegram.ChatIdHash.hash/2` (already in place from PR #1a).
- Bot token access: `Alethea.Telegram.BotToken.bot_token/0` (already in place from PR #1a, fail-loud on missing row).

## TDD Evidence template (copy-paste for the next session's apply-progress)

The previous session's apply-progress.md §"PR #2" has a copy-paste-ready template for the 8-task TDD evidence table. The next session should append a similar section for PR #3a, with the 4-task table:

```markdown
## Plan (4 tasks, all complete)

| ID | Title | Est. lines | Final SHA |
|---|---|---|---|
| TASK-3a-1 | TelegramMessageWorker full body (idempotency + patient resolution + safe clinical round-trip) | 350 | TBD |
| TASK-3a-2 | TelegramOutboundWorker (Pacer + 429 + dead-letter) + TelegramDeadLetter schema + migration | 250 (incl. schema + migration) | TBD |
| TASK-3a-3 | TelegramDeadLetter schema + migration (folded into TASK-3a-2) | — | — |
| TASK-3a-4 | Telegram.Client.Req production adapter | 60 | TBD |
| **Total** | | **~660** (740 est. – 80 folded) | |
```

Plus the TDD evidence table (RED-GREEN-REFACTOR per task), deviations, blockers, out-of-scope, and "Next step" pointing to PR #3b.

## Next session — the ritual

1. **Open the `sdd/telegram-paciente-foundation` branch** to see all the SDD artifacts (proposal, design, tasks, specs, apply-progress with the PR #2 section, verify reports).
2. **Read this HANDOFF.md** to remember the preflight + decisions + state.
3. **Confirm the SDD Session Preflight** with the user:
   - A1 (Interactive) / A2 (Auto)
   - B1 (OpenSpec) / B2 (Engram) / B3 (Both)
   - C3 (Chained — locked from the chain strategy)
   - D2 (800 lines — locked from the chain plan)
4. **Check `git status` and `git log --oneline -5` on `pr-1b-foundations-b`** to confirm the chain tip is at `7470de8` (PR #2 merge commit).
5. **Create `feat/telegram-paciente-foundation/pr-3a-clinical-safe` from `pr-1b-foundations-b`**.
6. **Work inline, not via sdd-apply** (the sub-agent is unreliable in this environment — see §"Decisions" item 3 above).
7. **Start with TASK-3a-1 (TelegramMessageWorker full body)** — the largest task. Strict TDD. Stop after each task in A1 mode and wait for the user to confirm.
8. **Update `apply-progress.md`** after each task on the sdd branch (merge or rebase as needed).
9. **After all 4 tasks, run `mix precommit` + `gh pr create` against `pr-1b-foundations-b`**.
10. **Do not start PR #3b in the same session** — the chain strategy is one PR per session to keep review surfaces tight. PR #3b can land in a follow-up session.

## TL;DR for the next session

> The user worked 5+ hours on the `telegram-paciente-foundation` change and closed with PR #1a, #1b, #1b-fixes, and #2 all merged. The chain is at `pr-1b-foundations-b` (commit `7470de8`). PR #3a is next: 4 tasks, ~740 lines, the clinical safe path. Strict TDD. Inline work (the sdd-apply sub-agent is unreliable here). The preflight is A1+B1+C3+D2. Don't re-litigate the decisions in §"Decisions established" above.
