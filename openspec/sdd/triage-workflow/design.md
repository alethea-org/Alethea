# Design — triage-workflow

**Source PR:** alethea-org/Alethea#152
**Approach:** 1 — workflows + slash commands + label state machine (selected in proposal)
**Artifact store:** hybrid
**Strict TDD:** active
**Inputs:** `proposal.md`, `exploration.md`, `spec.md`

## 1. Architecture approach

No new architectural layer in the Phoenix app. The triage workflow lives **entirely in GitHub configuration**: workflows (`.github/workflows/*.yml`), issue/PR templates, and the pinned tracking issue #150. The Phoenix code (`lib/`, `test/`) is untouched.

The state machine of an issue is **label-driven**. Labels (`status:*`) are the single source of truth for the issue's lifecycle. Workflows transition the state in response to GitHub events.

```
┌─────────────────────────────────────────────────────────────────────┐
│                       GitHub Events                                  │
│  issues.opened / edited / assigned / unassigned                     │
│  issue_comment.created                                              │
│  pull_request.closed / ready_for_review                             │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│              .github/workflows/triage.yml (7 jobs)                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │ auto-triage-new  │  │ handle-slash-cmd │  │ hard-lock        │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │ cap-one-assignee │  │ pr-merged-done   │  │ pr-soft-check    │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘  │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       GitHub REST API                                │
│  issues.update / addAssignees / removeAssignees / addLabels / ...   │
└─────────────────────────────────────────────────────────────────────┘
```

## 2. Component map & data flow

### 2.1 State machine

```
                          /claim         PR merged
[needs-triage] ─────────────────► [claimed] ─────────────► [done]
     ▲                              │    ▲
     │                              │    │
     │  /release                    │    │ /unblocked
     │  (or /release by PO)         │    │
     │                              ▼    │
     └──────────────────────  [blocked] ─┘
                          /blocked <razón>
```

Implemented by label transitions, NOT by a state machine library. Labels are the data.

### 2.2 Authorization model

```
Action: /claim on issue #N
  ┌─ Author is MEMBER or OWNER?  ── No ──► "🔒 Solo miembros..."
  │
  └─ Yes
       │
       ┌─ Issue has wayfinder:prototype or wayfinder:grilling?  ── Yes ──► "🚫 Solo el PO..."
       │
       └─ No
            │
            ┌─ Issue has any assignee?  ── Yes ──► "❌ Ya tomada por @X"
            │
            └─ No
                 │
                 ▼
                 Assign author, set status:claimed, remove status:needs-triage
```

```
Action: edit assignees on issue #N (issues.edited event)
  ┌─ Actor == current PO?  ── Yes ──► Comment "🔧 PO reasignó", preserve
  │
  └─ No
       │
       ┌─ Actor == current assignee AND change is net-zero or self-assign?  ── Yes ──► Allow silently
       │
       └─ No
            ▼
            Revert assignees, comment "🔒 Asignación protegida"
```

The "current PO" is read from `.github/ROTA.yml` at workflow runtime via `github.rest.repos.getContent`.

### 2.3 Workflow job specs

#### `auto-triage-new`
- Trigger: `issues.opened`
- Permissions: `issues: write`
- Logic: read existing labels, add `status:needs-triage` only if not present (idempotent).

#### `handle-slash-command`
- Trigger: `issue_comment.created`
- Permissions: `issues: write`
- Steps:
  1. Parse command (trim, lowercase, take first token). If not `/claim`, `/release`, `/blocked`, `/unblocked` → noop.
  2. Branch by command:
     - `/claim` → member check → wayfinder exempt → assignee check → assign + relabel
     - `/release` → assignee check → unassign + relabel
     - `/blocked <razón>` → assignee check → add `status:blocked` + comment with reason
     - `/unblocked` → assignee check + blocked check → remove `status:blocked`, add `status:claimed`
  3. Each branch posts a comment confirming or explaining the rejection.

#### `hard-lock`
- Trigger: `issues.edited` (only when `changes.assignees` exists)
- Permissions: `issues: write, contents: read`
- Steps:
  1. Read `.github/ROTA.yml` → extract `current_po`.
  2. Compare `actor` (sender) to `current_po` → allow with PO comment.
  3. Compute added/removed assignees. If `added[0] == actor` (self-assign) or `removed[0] == actor` (self-unassign) → allow.
  4. Otherwise → call `setAssignees` with the previous state + comment with the PO mention.

#### `cap-one-assignee`
- Trigger: `issues.edited`
- Permissions: `issues: write`
- Steps:
  1. Read current `issue.assignees`. If ≤1 → noop.
  2. Otherwise → set assignees to `[assignees[0]]` + comment explaining.

#### `pr-merged-status-done`
- Trigger: `pull_request.closed` with `merged: true`
- Permissions: `issues: write`
- Steps:
  1. Parse PR body for `Closes #N`, `Fixes #N`, `Resolves #N` patterns.
  2. For each referenced issue: if it has `status:claimed` → swap to `status:done`, comment "✅ Issue cerrada vía PR #Y".

#### `pr-soft-check`
- Trigger: `pull_request.ready_for_review`
- Permissions: `issues: read, pull-requests: write`
- Steps:
  1. Parse PR body for closing patterns.
  2. For each referenced issue: get current assignee. If `assignee != null && assignee != pr_author && assignee != current_po` → comment on PR "ℹ️ Esta PR cierra #N (asignada a @X) pero el autor es @Y. ¿Intencional?"

### 2.4 Rotation workflow (`.github/workflows/rotate.yml`)

Trigger: cron `0 13 * * 1` (Monday 10:00 ART, UTC-3) + `workflow_dispatch`.

Steps:
1. `actions/checkout@v4` to read `.github/ROTA.yml`.
2. Parse `order` and `current_po` via `actions/github-script` + `js-yaml`.
3. Compute `next = order[(indexOf(current_po) + 1) % order.length]`.
4. Update `.github/ROTA.yml` in-place (`current_po` + `last_rotated`).
5. `git commit` + `git push` as the bot user.
6. Find issue with label `triage-rota` (issue #150). If not found → noop (log warning).
7. Update #150 body with the new PO + comment explaining the rotation.

### 2.5 Setup-labels workflow (`.github/workflows/setup-labels.yml`)

Trigger: `workflow_dispatch` only.

Steps:
1. Define 16 labels (3 `status:*`, 3 `priority:*`, 8 `area:*`, 1 `triage:rotating`, 1 internal `triage-rota`).
2. For each label: if exists → `updateLabel`, else → `createLabel`.
3. Write summary with counts of created / updated / failed.

## 3. Error / fail-loud handling

| Condition | Bot action |
|---|---|
| Comment body has trailing whitespace or extra args on `/claim` | Stripped with `.trim().split(/\s+/)[0]` → only the command matters |
| Comment body has trailing whitespace on `/release` | Same normalization → noop if mismatched |
| `/claim` from non-member | Soft fail with comment explaining |
| `/claim` on wayfinder exempt | Soft fail with comment explaining |
| `/claim` on taken issue | Soft fail with comment naming the current assignee |
| `/release` from non-assignee | Soft fail with comment naming the assignee |
| `/blocked` from non-assignee | Soft fail |
| `/blocked` without a reason | Accept (empty reason is allowed) but log |
| `/unblocked` on non-blocked issue | Soft fail with comment |
| Edit assignees by non-authorized | Revert + comment with PO mention |
| Edit assignees with >1 result | Keep first + comment |
| `rotate.yml` runs but no `triage-rota` issue exists | Noop with warning (logged) |
| `setup-labels.yml` runs but permissions insufficient | Fail loud (Action errors visibly) |

All failures are soft (comment + noop) except `setup-labels.yml` (loud — it's a one-shot bootstrap).

## 4. Permissions matrix

| Workflow | `issues` | `contents` | `pull-requests` | `actions` |
|---|:---:|:---:|:---:|:---:|
| `triage.yml` (all jobs) | write | read | read | — |
| `rotate.yml` | write | write | read | — |
| `setup-labels.yml` | write | — | — | — |
| `elixir.yml` (existing, untouched) | — | — | — | — |

## 5. Data flow (happy path)

```
User opens issue #N (bug template)
  ↓
[GitHub: issues.opened event]
  ↓
triage.yml → auto-triage-new
  ↓ (api call)
issue #N has label: status:needs-triage

User @dev comments "/claim"
  ↓
[GitHub: issue_comment.created event]
  ↓
triage.yml → handle-slash-command (claim branch)
  ├─ author is MEMBER? ✓
  ├─ wayfinder exempt? no
  ├─ any assignee? no
  ├─ api: addAssignees([@dev])
  ├─ api: addLabels(["status:claimed"])
  ├─ api: removeLabel("status:needs-triage")
  └─ api: createComment("✅ Tomada por @dev. Lock activo.")

User @dev opens PR with body "Closes #N", marked as draft
  ↓ (no event yet — PR is in draft)

User @dev marks PR as ready for review
  ↓
[GitHub: pull_request.ready_for_review event]
  ↓
triage.yml → pr-soft-check
  ├─ parse "Closes #N"
  ├─ issue #N assignee == @dev == PR author
  └─ no comment (everything consistent)

PR merged
  ↓
[GitHub: pull_request.closed with merged:true event]
  ↓
triage.yml → pr-merged-status-done
  ├─ parse "Closes #N"
  ├─ issue #N has status:claimed
  ├─ api: removeLabel("status:claimed")
  ├─ api: addLabels(["status:done"])
  └─ api: createComment("✅ Issue cerrada vía PR #Y. status:done")
```

## 6. ADR-style decisions

- **ADR-D1 — Slash commands over UI buttons.** Rationale: simple to implement (`actions/github-script` + `issue_comment`), works for all team members without browser extensions. UI-based claim would require GitHub Apps with custom UI elements — out of scope.
- **ADR-D2 — Labels as state machine, not a separate `state` field.** Rationale: GitHub API has no issue state field beyond `open`/`closed`. Labels are the only native way to encode multi-state lifecycle. Bonus: filterable on the dashboard.
- **ADR-D3 — `ROTA.yml` over `ROTA.json`.** Rationale: matches the project's preference for YAML in `.github/`. Also matches `openspec/config.yaml`.
- **ADR-D4 — Soft PR check (comment) over hard block (status check).** Rationale: the team wants visibility, not gatekeeping. If the PO disagrees with the author mismatch, they can intervene in the PR review. A blocking check would create process overhead without clear benefit.
- **ADR-D5 — `status:done` is permanent.** Rationale: it serves as an audit seal for the "Proyecto" delivery. Removing it on issue reopen would lose that audit signal. Documented in CONTRIBUTING.

## 7. Out of scope (reference only)

- `CODEOWNERS` per area — PRs future.
- Weekly metrics summary — rejected (Q6).
- Slack/Discord notifications on rotation — not requested.
- Auto-claim via UI button — slash command only for v1.
- Bot account separation (`alethea-triage-bot`) — rejected (Approach 2).
